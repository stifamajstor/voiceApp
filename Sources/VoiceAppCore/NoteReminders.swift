import Foundation
import UserNotifications

public enum NoteNotificationAuthorization: Sendable {
    case notDetermined, denied, authorized
}

public struct NoteNotification: Equatable, Sendable {
    public let noteID: UUID
    public let text: String
    public let date: Date?
    public var identifier: String { Self.identifier(for: noteID) }

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
        let content = UNMutableNotificationContent()
        content.title = "VoiceApp reminder"
        content.body = notification.text
        content.sound = .default
        let trigger = notification.date.map {
            UNTimeIntervalNotificationTrigger(timeInterval: max(1, $0.timeIntervalSinceNow), repeats: false)
        }
        try await center.add(UNNotificationRequest(identifier: notification.identifier, content: content, trigger: trigger))
    }

    public func remove(identifiers: Set<String>) {
        center.removePendingNotificationRequests(withIdentifiers: Array(identifiers))
        center.removeDeliveredNotifications(withIdentifiers: Array(identifiers))
    }
}

@MainActor
public final class NoteReminderScheduler {
    private let center: any NoteNotificationCenter

    public init(center: any NoteNotificationCenter) { self.center = center }

    public func authorization(requestIfNeeded: Bool) async throws -> Bool {
        switch await center.authorization() {
        case .authorized: return true
        case .notDetermined where requestIfNeeded: return try await center.requestAuthorization()
        default: return false
        }
    }

    public func remove(id: UUID) { center.remove(identifiers: [NoteNotification.identifier(for: id)]) }

    public func removeOrphans(notes: [VoiceNote]) async {
        let active = Set(notes.filter { !$0.isDone && $0.reminderDate != nil }.map { NoteNotification.identifier(for: $0.id) })
        let pending = await center.pendingIdentifiers()
        let delivered = await center.deliveredIdentifiers()
        let owned = pending.union(delivered).filter { NoteNotification.noteID(for: $0) != nil }
        center.remove(identifiers: Set(owned).subtracting(active))
    }

    /// Returns true once an overdue reminder has been delivered or found in Notification Center.
    public func schedule(_ note: VoiceNote, now: Date, catchUp: Bool) async throws -> Bool {
        guard !note.isDone, let date = note.reminderDate else { remove(id: note.id); return false }
        if date > now {
            try await center.add(NoteNotification(noteID: note.id, text: note.text, date: date))
            return false
        }
        guard catchUp, note.reminderNotifiedAt == nil else { return false }
        let identifier = NoteNotification.identifier(for: note.id)
        if !(await center.deliveredIdentifiers()).contains(identifier) {
            try await center.add(NoteNotification(noteID: note.id, text: note.text, date: nil))
        }
        return true
    }
}
