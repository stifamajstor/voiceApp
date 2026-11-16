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
    /// For a summary: the requests of the reminders it stands in for.
    public let covers: [String]
    public var identifier: String {
        guard let noteID else { return Self.summaryIdentifier }
        return Self.identifier(for: noteID, due: due ?? date)
    }
    public static let summaryIdentifier = "voice-note-summary"

    public init(noteID: UUID?, text: String, date: Date?, due: Date? = nil, covers: [String] = []) {
        self.noteID = noteID
        self.text = text
        self.date = date
        self.due = due ?? date
        self.covers = covers
    }

    /// One identifier per note and due time. A notification still in Notification Center therefore
    /// belongs to exactly one due time, never to an earlier one the reminder was moved from.
    public static func identifier(for id: UUID, due: Date?) -> String {
        guard let due else { return "voice-note.\(id.uuidString)" }
        return "voice-note.\(id.uuidString).\(ReminderState.key(due))"
    }

    public static func noteID(for identifier: String) -> UUID? {
        guard identifier.hasPrefix("voice-note.") else { return nil }
        let rest = identifier.dropFirst("voice-note.".count)
        return UUID(uuidString: String(rest.prefix(36)))
    }

    /// The due time an identifier was made for. Identifiers from before due times were part of them have none.
    public static func dueDate(for identifier: String) -> Date? {
        let parts = identifier.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "voice-note", UUID(uuidString: String(parts[1])) != nil,
              let milliseconds = Int64(parts[2]) else { return nil }
        return Date(timeIntervalSince1970: Double(milliseconds) / 1000)
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


public struct ReminderReconcileResult {
    /// When VoiceApp needs to look again without any outside event. `nil` when nothing is waiting.
    public let nextWake: Date?
    public let error: (any Error)?
}

/// Saves one transition if the note's state is still `from`. Returns whether it was saved.
public typealias ReminderPersist = @MainActor (_ id: UUID, _ from: ReminderState, _ to: ReminderState) async throws -> Bool

/// Carries out what the state machine and the plan decide. It holds no alert state of its own: it
/// reads the saved states, applies events, and talks to the notification center.
@MainActor
public final class NoteReminderScheduler {
    /// How many requests macOS lets an app hold.
    nonisolated public static let pendingLimit = 60
    private let center: any NoteNotificationCenter
    private let limit: Int

    public init(center: any NoteNotificationCenter, limit: Int = NoteReminderScheduler.pendingLimit) {
        self.center = center
        self.limit = limit
    }

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

    /// Notifications of notes that were removed, finished, or moved to another due time.
    public func removeOrphans(notes: [VoiceNote]) async {
        let active = Set(notes.filter(\.hasActiveReminder)
            .map { NoteNotification.identifier(for: $0.id, due: $0.reminderDate) })
        let pending = await center.pendingIdentifiers()
        let delivered = await center.deliveredIdentifiers()
        let owned = pending.union(delivered).filter { NoteNotification.noteID(for: $0) != nil }
        let orphans = owned.subtracting(active)
        if !orphans.isEmpty { center.remove(identifiers: orphans) }
    }

    /// Bring macOS in line with the saved states of `notes`, the notes that carry a reminder.
    ///
    /// 1. Reminders whose due time was reached move on (`scheduled` to `missed`, `handedToMacOS` to `alerted`).
    /// 2. Requests outside the window are taken back, requests inside it are added or repaired.
    /// 3. Missed reminders get their one catch-up alert, as a single summary when there are several.
    ///
    /// `authorized` decides only whether a request can be added or an alert posted now. It never
    /// changes a state: a request that was with macOS stays evidence of that.
    public func reconcile(notes: [VoiceNote], now: Date, authorized: Bool, afterLaunch: Bool,
                          resubmit: ReminderResubmit = .none, persist: ReminderPersist) async -> ReminderReconcileResult {
        let notes = notes.filter(\.hasActiveReminder)
        var states = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0.reminder) })
        let texts = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0.text) })
        var firstError: (any Error)?

        /// The table decides the new state, the store keeps it. A note that changed under us is left alone.
        func apply(_ event: ReminderEvent, to id: UUID) async {
            guard let current = states[id] else { return }
            let next = ReminderStateMachine.next(current, event)
            guard next != current else { return }
            do {
                if try await persist(id, current, next) { states[id] = next } else { states[id] = nil }
            } catch { firstError = firstError ?? error }
        }

        await removeOrphans(notes: notes)
        for note in notes { await apply(.timeReached(now), to: note.id) }
        let plan = ReminderPlan.make(states, now: now, authorized: authorized, limit: limit,
                                     pending: await center.pendingIdentifiers(), resubmit: resubmit)

        for id in plan.withdraw {
            guard let due = states[id]?.dueAt else { continue }
            center.remove(identifiers: [NoteNotification.identifier(for: id, due: due)])
            await apply(.requestWithdrawn(due), to: id)
        }
        for id in plan.hand {
            guard let due = states[id]?.dueAt, let text = texts[id] else { continue }
            do {
                try await center.add(NoteNotification(noteID: id, text: text, date: due))
                await apply(.requestAdded(due), to: id)
            } catch { firstError = firstError ?? error }
        }

        let owed: [(id: UUID, due: Date)] = plan.catchUp.compactMap { id in
            if case .missed(let due)? = states[id] { return (id, due) }
            return nil
        }
        if !owed.isEmpty {
            do {
                if owed.count > 1 {
                    let text = afterLaunch
                        ? "\(owed.count) reminders were due while VoiceApp was closed"
                        : "\(owed.count) reminders are due"
                    try await center.add(NoteNotification(noteID: nil, text: text, date: nil,
                        covers: owed.map { NoteNotification.identifier(for: $0.id, due: $0.due) }))
                } else if let only = owed.first {
                    try await center.add(NoteNotification(noteID: only.id, text: texts[only.id] ?? "", date: nil, due: only.due))
                }
                for reminder in owed { await apply(.catchUpPosted(reminder.due), to: reminder.id) }
            } catch { firstError = firstError ?? error }
        }
        return ReminderReconcileResult(nextWake: plan.nextWake, error: firstError)
    }
}
