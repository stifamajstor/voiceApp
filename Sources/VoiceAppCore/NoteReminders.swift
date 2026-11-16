import EventKit
import Foundation

@MainActor
public protocol NoteReminderService {
    func requestAccess() async throws -> Bool
    func create(title: String, date: Date) throws -> String
    func remove(identifier: String) throws
}

public enum ReminderError: LocalizedError {
    case accessDenied, noDefaultList

    public var errorDescription: String? {
        switch self {
        case .accessDenied: return "Reminders access is denied. Enable VoiceApp in System Settings → Privacy & Security → Reminders, then try again."
        case .noDefaultList: return "No default Reminders list is available. Create a list in Apple Reminders, then try again."
        }
    }
}

@MainActor
public final class EventKitNoteReminders: NoteReminderService {
    private let store: EKEventStore

    public init(store: EKEventStore = EKEventStore()) { self.store = store }

    public func requestAccess() async throws -> Bool {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: return true
        case .notDetermined: return try await store.requestFullAccessToReminders()
        default: return false
        }
    }

    public func create(title: String, date: Date) throws -> String {
        guard let calendar = store.defaultCalendarForNewReminders() else { throw ReminderError.noDefaultList }
        return try create(title: title, date: date, calendar: calendar)
    }

    public func create(title: String, date: Date, calendar: EKCalendar) throws -> String {
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = calendar
        reminder.title = title
        var components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        components.timeZone = .current
        reminder.dueDateComponents = components
        reminder.addAlarm(EKAlarm(absoluteDate: date))
        try store.save(reminder, commit: true)
        return reminder.calendarItemIdentifier
    }

    public func remove(identifier: String) throws {
        guard let reminder = store.calendarItem(withIdentifier: identifier) as? EKReminder else { return }
        try store.remove(reminder, commit: true)
    }
}
