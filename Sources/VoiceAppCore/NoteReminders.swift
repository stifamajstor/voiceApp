import Foundation
import UserNotifications

public enum NoteNotificationAuthorization: Sendable {
    case notDetermined, denied, authorized

    public var disclosure: String? {
        switch self {
        case .notDetermined:
            return "Notification permission has not been asked yet. Refresh notifications to allow VoiceApp reminders."
        case .denied:
            return "Notifications are turned off for VoiceApp. Enable VoiceApp in System Settings → Notifications."
        case .authorized: return nil
        }
    }
}

public struct NoteNotification: Equatable, Sendable {
    public let noteID: UUID?
    public let text: String
    public let date: Date?
    public var identifier: String { noteID.map(Self.identifier(for:)) ?? Self.summaryIdentifier }
    public static let summaryIdentifier = "voice-note-summary"

    public static func identifier(for id: UUID) -> String { "voice-note.\(id.uuidString)" }
    public static func noteID(for identifier: String) -> UUID? {
        guard identifier.hasPrefix("voice-note.") else { return nil }
        return UUID(uuidString: String(identifier.dropFirst("voice-note.".count)))
    }
}

@MainActor
public protocol NoteNotificationCenter {
    func authorization() async -> NoteNotificationAuthorization
    func requestAuthorization() async throws -> Bool
    func pendingIdentifiers() async -> Set<String>
    func deliveredIdentifiers() async -> Set<String>
    func add(_ notification: NoteNotification) async throws
    func remove(identifiers: Set<String>)
}

@MainActor
public final class SystemNoteNotificationCenter: NoteNotificationCenter {
    private var center: UNUserNotificationCenter { .current() }

    public init() {}

    public func authorization() async -> NoteNotificationAuthorization {
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined: return .notDetermined
        case .authorized, .provisional, .ephemeral: return .authorized
        default: return .denied
        }
    }

    public func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound])
    }

    public func pendingIdentifiers() async -> Set<String> {
        Set(await center.pendingNotificationRequests().map(\.identifier))
    }

    public func deliveredIdentifiers() async -> Set<String> {
        Set(await center.deliveredNotifications().map { $0.request.identifier })
    }

    public func add(_ notification: NoteNotification) async throws {
        try await center.add(Self.request(for: notification))
    }

    public static func request(for notification: NoteNotification, timeZone: TimeZone = .current) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = "VoiceApp reminder"
        content.body = notification.text
        content.sound = .default
        let trigger = notification.date.map { Self.calendarTrigger(for: $0, timeZone: timeZone) }
        return UNNotificationRequest(identifier: notification.identifier, content: content, trigger: trigger)
    }

    /// Use local calendar components, disambiguating the second occurrence of a repeated hour.
    public static func calendarTrigger(for date: Date, timeZone: TimeZone = .current) -> UNCalendarNotificationTrigger {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        components.timeZone = timeZone
        if let reconstructed = calendar.date(from: components), abs(reconstructed.timeIntervalSince(date)) >= 1 {
            // Calendar triggers choose the first repeated hour. Its UTC offset distinguishes the second.
            components.timeZone = TimeZone(secondsFromGMT: timeZone.secondsFromGMT(for: date))
        }
        return UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
    }

    public func remove(identifiers: Set<String>) {
        center.removePendingNotificationRequests(withIdentifiers: Array(identifiers))
        center.removeDeliveredNotifications(withIdentifiers: Array(identifiers))
    }
}

@MainActor
public final class NoteReminderScheduler {
    public static let pendingLimit = 60
    private let center: any NoteNotificationCenter

    public init(center: any NoteNotificationCenter) { self.center = center }

    public func authorization(requestIfNeeded: Bool) async throws -> NoteNotificationAuthorization {
        let status = await center.authorization()
        if status == .notDetermined, requestIfNeeded {
            return try await center.requestAuthorization() ? .authorized : .denied
        }
        return status
    }

    public func remove(id: UUID) { center.remove(identifiers: [NoteNotification.identifier(for: id)]) }

    public func removeOrphans(notes: [VoiceNote]) async {
        let active = Set(notes.filter { !$0.isDone && $0.reminderDate != nil }.map { NoteNotification.identifier(for: $0.id) })
        let pending = await center.pendingIdentifiers()
        let delivered = await center.deliveredIdentifiers()
        let owned = pending.union(delivered).filter { NoteNotification.noteID(for: $0) != nil }
        center.remove(identifiers: Set(owned).subtracting(active))
    }

    /// Reconcile as a batch so missed reminders produce at most one catch-up alert.
    public func reconcile(notes: [VoiceNote], now: Date, catchUp: Bool,
                          didSchedule: (UUID, Date?) async throws -> Void,
                          didAlert: (UUID) async throws -> Void) async throws {
        await removeOrphans(notes: notes)
        var firstError: (any Error)?
        let future = notes.filter { !$0.isDone && $0.reminderDate.map({ $0 > now }) == true }.sorted {
            if $0.reminderDate == $1.reminderDate { return $0.id.uuidString < $1.id.uuidString }
            return $0.reminderDate! < $1.reminderDate!
        }
        let scheduled = Array(future.prefix(Self.pendingLimit))
        let deferred = Array(future.dropFirst(Self.pendingLimit))
        center.remove(identifiers: Set(deferred.map { NoteNotification.identifier(for: $0.id) }))
        for note in deferred where note.reminderScheduledFor != nil {
            try await didSchedule(note.id, nil)
        }
        for note in scheduled {
            do {
                try await center.add(NoteNotification(noteID: note.id, text: note.text, date: note.reminderDate))
                try await didSchedule(note.id, note.reminderDate)
            } catch { firstError = firstError ?? error }
        }
        if catchUp {
            let due = notes.filter { !$0.isDone && $0.reminderDate.map({ $0 <= now }) == true && $0.reminderNotifiedAt == nil }
            let delivered = await center.deliveredIdentifiers()
            let missed = due.filter {
                $0.reminderScheduledFor != $0.reminderDate && !delivered.contains(NoteNotification.identifier(for: $0.id))
            }
            do {
                if missed.count > 1 {
                    try await center.add(NoteNotification(noteID: nil,
                        text: "\(missed.count) reminders were due while VoiceApp was closed", date: nil))
                } else if let note = missed.first {
                    try await center.add(NoteNotification(noteID: note.id, text: note.text, date: nil))
                }
                for note in due { try await didAlert(note.id) }
            } catch { firstError = firstError ?? error }
        }
        if let firstError { throw firstError }
    }
}
