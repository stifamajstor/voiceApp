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
    /// When the request fires. `nil` alerts immediately (catch-up and summary alerts).
    public let date: Date?
    /// The due time this alert is for. An immediate catch-up carries the due time it stands in for.
    public let due: Date?
    public var identifier: String {
        guard let noteID else { return Self.summaryIdentifier }
        return Self.identifier(for: noteID, due: due ?? date)
    }
    public static let summaryIdentifier = "voice-note-summary"

    public init(noteID: UUID?, text: String, date: Date?, due: Date? = nil) {
        self.noteID = noteID
        self.text = text
        self.date = date
        self.due = due ?? date
    }

    /// One identifier per note and due time. A notification still in Notification Center therefore
    /// proves only that this due time was alerted, never an earlier one the reminder was moved from.
    public static func identifier(for id: UUID, due: Date?) -> String {
        guard let due else { return "voice-note.\(id.uuidString)" }
        return "voice-note.\(id.uuidString).\(Int64((due.timeIntervalSince1970 * 1000).rounded()))"
    }

    public static func noteID(for identifier: String) -> UUID? {
        guard identifier.hasPrefix("voice-note.") else { return nil }
        let rest = identifier.dropFirst("voice-note.".count)
        return UUID(uuidString: String(rest.prefix(36)))
    }
}

/// Why a reconcile is allowed to alert for reminders that came due without a macOS notification.
public enum ReminderCatchUp: Sendable {
    /// Top up and repair only. Never alert.
    case off
    /// VoiceApp was just opened, so it was not running when these came due.
    case afterLaunch
    /// VoiceApp was running when these came due.
    case running
}

/// Which reminders to hand to macOS again even if a matching request is already pending.
public enum ReminderResubmit: Sendable {
    case none
    case notes(Set<UUID>)
    case all
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

    public static func request(for notification: NoteNotification, timeZone: TimeZone = .current,
                               now: Date = .now) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = "VoiceApp reminder"
        content.body = notification.text
        content.sound = .default
        let trigger = notification.date.map { Self.trigger(for: $0, timeZone: timeZone, now: now) }
        return UNNotificationRequest(identifier: notification.identifier, content: content, trigger: trigger)
    }

    /// A calendar trigger has whole-second resolution and never fires once its second has passed.
    /// Due times round up to the next whole second so a reminder is never early, and a time that is
    /// a moment away uses an interval trigger so it cannot miss its second while being handed over.
    public static func trigger(for date: Date, timeZone: TimeZone = .current, now: Date = .now) -> UNNotificationTrigger {
        let target = Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.up))
        let remaining = target.timeIntervalSince(now)
        if remaining < 2 {
            return UNTimeIntervalNotificationTrigger(timeInterval: max(1, remaining), repeats: false)
        }
        return calendarTrigger(for: target, timeZone: timeZone)
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

/// Wakes VoiceApp at the next reminder's due time, since macOS only tells a menu-bar app about
/// a delivered notification when the app is frontmost or the notification is clicked.
@MainActor
public protocol ReminderTimer: AnyObject {
    func arm(at date: Date, fire: @escaping @MainActor () -> Void)
    func cancel()
}

@MainActor
public final class SystemReminderTimer: ReminderTimer {
    private var task: Task<Void, Never>?

    public init() {}

    public func arm(at date: Date, fire: @escaping @MainActor () -> Void) {
        task?.cancel()
        task = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(max(1, date.timeIntervalSinceNow))) } catch { return }
            fire()
        }
    }

    public func cancel() {
        task?.cancel()
        task = nil
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

    /// Remove every pending and delivered notification of one note, whatever due time it carries.
    public func remove(id: UUID) async {
        let owned = await center.pendingIdentifiers().union(center.deliveredIdentifiers())
        center.remove(identifiers: owned.filter { NoteNotification.noteID(for: $0) == id })
    }

    public func removeOrphans(notes: [VoiceNote]) async {
        let active = Set(notes.filter { !$0.isDone && $0.reminderDate != nil }
            .map { NoteNotification.identifier(for: $0.id, due: $0.reminderDate) })
        let pending = await center.pendingIdentifiers()
        let delivered = await center.deliveredIdentifiers()
        let owned = pending.union(delivered).filter { NoteNotification.noteID(for: $0) != nil }
        let orphans = owned.subtracting(active)
        if !orphans.isEmpty { center.remove(identifiers: orphans) }
    }

    /// `notes` are the notes that carry a reminder. Reconcile as a batch so reminders that came due
    /// without a notification produce at most one catch-up alert.
    ///
    /// Every reminder alerts once per due time. A request handed to macOS for that due time is the
    /// alert; a reminder that was never handed over, or that came due while notifications were off,
    /// gets one immediate catch-up instead.
    public func reconcile(notes: [VoiceNote], now: Date, catchUp: ReminderCatchUp, resubmit: ReminderResubmit = .none,
                          didSchedule: (UUID, Date?) async throws -> Void,
                          didAlert: (UUID) async throws -> Void) async throws {
        await removeOrphans(notes: notes)
        var firstError: (any Error)?
        let pending = await center.pendingIdentifiers()
        let future = notes.filter { !$0.isDone && $0.reminderDate.map({ $0 > now }) == true }.sorted {
            if $0.reminderDate == $1.reminderDate { return $0.id.uuidString < $1.id.uuidString }
            return $0.reminderDate! < $1.reminderDate!
        }
        let scheduled = Array(future.prefix(Self.pendingLimit))
        let deferred = Array(future.dropFirst(Self.pendingLimit))
        center.remove(identifiers: Set(deferred.map { NoteNotification.identifier(for: $0.id, due: $0.reminderDate) }))
        for note in deferred where note.reminderScheduledFor != nil {
            try await didSchedule(note.id, nil)
        }
        for note in scheduled {
            let identifier = NoteNotification.identifier(for: note.id, due: note.reminderDate)
            if note.reminderScheduledFor == note.reminderDate, pending.contains(identifier), !resubmit.includes(note.id) {
                continue
            }
            do {
                try await center.add(NoteNotification(noteID: note.id, text: note.text, date: note.reminderDate))
                try await didSchedule(note.id, note.reminderDate)
            } catch { firstError = firstError ?? error }
        }
        if catchUp != .off {
            let due = notes.filter { !$0.isDone && $0.reminderDate.map({ $0 <= now }) == true && $0.reminderNotifiedAt == nil }
            let delivered = await center.deliveredIdentifiers()
            let missed = due.filter {
                $0.reminderScheduledFor != $0.reminderDate
                    && !delivered.contains(NoteNotification.identifier(for: $0.id, due: $0.reminderDate))
            }
            do {
                if missed.count > 1 {
                    let text = catchUp == .afterLaunch
                        ? "\(missed.count) reminders were due while VoiceApp was closed"
                        : "\(missed.count) reminders are due"
                    try await center.add(NoteNotification(noteID: nil, text: text, date: nil))
                } else if let note = missed.first {
                    try await center.add(NoteNotification(noteID: note.id, text: note.text, date: nil, due: note.reminderDate))
                }
                for note in due { try await didAlert(note.id) }
            } catch { firstError = firstError ?? error }
        }
        if let firstError { throw firstError }
    }

    /// Notifications are off: a reminder handed over for a due time that has passed was probably not
    /// shown. Forget the handoff so the first reconcile with notifications on alerts for it once.
    public func forgetHandoffs(notes: [VoiceNote], now: Date,
                               didSchedule: (UUID, Date?) async throws -> Void) async throws {
        for note in notes where !note.isDone && note.reminderNotifiedAt == nil && note.reminderScheduledFor != nil
            && note.reminderDate.map({ $0 <= now }) == true {
            try await didSchedule(note.id, nil)
        }
    }
}

extension ReminderResubmit {
    func includes(_ id: UUID) -> Bool {
        switch self {
        case .none: return false
        case .notes(let ids): return ids.contains(id)
        case .all: return true
        }
    }
}
