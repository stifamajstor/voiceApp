import Foundation
import UserNotifications
import XCTest
@testable import VoiceAppCore

private final class TestClock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}

/// Every reminder alerts exactly once for each due time it is set to: never zero, never twice.
@MainActor
final class ReminderEdgeCaseTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var defaultsName: String!
    private let start = Date(timeIntervalSince1970: 1_900_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "ReminderEdge-\(UUID())")
        defaultsName = "ReminderEdge.\(UUID())"
        defaults = UserDefaults(suiteName: defaultsName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: directory)
    }

    private func make(_ fake: FakeNotifications, _ clock: TestClock, timer: FakeReminderTimer? = nil,
                      events: NotificationCenter = NotificationCenter()) -> DictationHistory {
        DictationHistory(repository: SQLiteHistoryRepository(directory: directory), notifications: fake,
                         notificationEvents: events, reminderTimer: timer ?? FakeReminderTimer(), now: { clock.now },
                         defaults: defaults, debounce: { _ in }, log: { _ in })
    }

    private func newNote(_ history: DictationHistory, _ text: String) async -> UUID {
        let dictation = CompletedDictation(rawText: "raw \(text)", finalText: text, appBundleID: nil, appName: nil,
                                           modelID: "test", durationSeconds: 2)
        await history.deliver(dictation, destination: .note) { _ in XCTFail("Notes never paste") }
        await history.pendingSave?.value
        return dictation.id
    }

    private func seed(_ count: Int, spacing: TimeInterval = 60) throws -> [UUID] {
        let store = try MemoryStore(directory: directory)
        defer { try? store.close() }
        return try (0..<count).map { index in
            let note = try store.append(kind: .note, rawText: "reminder \(index)")
            try store.setNoteReminder(id: note.id, date: start.addingTimeInterval(Double(index + 1) * spacing))
            return note.id
        }
    }

    private func key(_ id: UUID, in identifiers: some Collection<String>) -> String? {
        identifiers.first { NoteNotification.noteID(for: $0) == id }
    }

    /// macOS presents a pending request at its due time. A click or Clear All then removes the delivered entry.
    private func present(_ fake: FakeNotifications, _ id: UUID, clear: Bool) {
        guard let identifier = key(id, in: fake.pending.keys) else { return XCTFail("request was not pending at its due time") }
        fake.pending[identifier] = nil
        if !clear { fake.delivered.insert(identifier) }
    }

    private func catchUpAlerts(_ fake: FakeNotifications) -> [String] {
        fake.added.filter { $0.date == nil }.map(\.text)
    }

    private func wake(_ history: DictationHistory, _ timer: FakeReminderTimer) async {
        timer.fire()
        await history.pendingSave?.value
    }

    // MARK: Delivered identity is per due time

    func testIdentifierBelongsToTheDueTime() {
        let id = UUID()
        let first = NoteNotification.identifier(for: id, due: start)
        XCTAssertNotEqual(first, NoteNotification.identifier(for: id, due: start.addingTimeInterval(60)))
        XCTAssertEqual(first, NoteNotification.identifier(for: id, due: start))
        XCTAssertEqual(NoteNotification.noteID(for: first), id)
        XCTAssertEqual(NoteNotification.noteID(for: "voice-note.\(id.uuidString)"), id, "older identifiers still map to their note")
        XCTAssertNil(NoteNotification.noteID(for: NoteNotification.summaryIdentifier))
        let later = NoteNotification(noteID: id, text: "x", date: nil, due: start.addingTimeInterval(60))
        XCTAssertEqual(later.identifier, NoteNotification.identifier(for: id, due: start.addingTimeInterval(60)))
    }

    func testReSetAfterFiringAlertsOncePerDueTime() async throws {
        let fake = FakeNotifications()
        let clock = TestClock(start)
        let history = make(fake, clock)
        let id = await newNote(history, "reset")
        await history.remindNote(id: id, date: clock.now.addingTimeInterval(600)).value
        clock.now = clock.now.addingTimeInterval(700)
        present(fake, id, clear: true)
        fake.added = []
        // Still running: the user re-sets it to a later time. Nothing alerts now.
        await history.remindNote(id: id, date: clock.now.addingTimeInterval(600)).value
        XCTAssertEqual(catchUpAlerts(fake), [])
        XCTAssertNotNil(key(id, in: fake.pending.keys))
        // The second due time passes. The banner stays in Notification Center, untouched.
        clock.now = clock.now.addingTimeInterval(700)
        present(fake, id, clear: false)
        let relaunched = make(fake, clock)
        await relaunched.start().value
        XCTAssertEqual(catchUpAlerts(fake), [])
        // Re-set to a past time while that earlier banner is still there: one alert now, none later.
        await relaunched.remindNote(id: id, date: clock.now.addingTimeInterval(-60)).value
        XCTAssertEqual(catchUpAlerts(fake), ["reset"])
        fake.delivered = []
        await make(fake, clock).start().value
        XCTAssertEqual(catchUpAlerts(fake), ["reset"])
    }

    func testReSetToCurrentTimeAfterFiringAlertsOnce() async throws {
        let fake = FakeNotifications()
        let clock = TestClock(start)
        let history = make(fake, clock)
        let id = await newNote(history, "now")
        await history.remindNote(id: id, date: clock.now.addingTimeInterval(60)).value
        clock.now = clock.now.addingTimeInterval(90)
        present(fake, id, clear: false)
        fake.added = []
        await history.remindNote(id: id, date: clock.now).value
        XCTAssertEqual(catchUpAlerts(fake), ["now"])
    }

    func testReSetBeyondTheCapAlertsAtItsDueTimeWhileRunning() async throws {
        let second = start.addingTimeInterval(20_000)
        let store = try MemoryStore(directory: directory)
        for index in 0..<60 {
            let filler = try store.append(kind: .note, rawText: "filler \(index)")
            try store.setNoteReminder(id: filler.id, date: second.addingTimeInterval(-1))
        }
        try store.close()
        let fake = FakeNotifications()
        let clock = TestClock(start)
        let timer = FakeReminderTimer()
        let history = make(fake, clock, timer: timer)
        let id = await newNote(history, "beyond the cap")
        await history.remindNote(id: id, date: start.addingTimeInterval(60)).value
        XCTAssertNotNil(key(id, in: fake.pending.keys))
        clock.now = start.addingTimeInterval(90)
        present(fake, id, clear: false)
        fake.added = []
        await history.remindNote(id: id, date: second).value
        XCTAssertNil(key(id, in: fake.pending.keys), "behind 60 earlier reminders, so never handed to macOS")
        XCTAssertNil(key(id, in: fake.delivered), "the earlier due time's banner is withdrawn")
        clock.now = second.addingTimeInterval(1)
        await wake(history, timer)
        XCTAssertEqual(catchUpAlerts(fake), ["beyond the cap"])
        await wake(history, timer)
        await make(fake, clock).start().value
        XCTAssertEqual(catchUpAlerts(fake), ["beyond the cap"])
    }

    func testReSetWhileNotificationsAreOffAlertsOnceWhenTheyAreBackOn() async throws {
        let fake = FakeNotifications()
        let clock = TestClock(start)
        let history = make(fake, clock)
        let id = await newNote(history, "set while off")
        await history.remindNote(id: id, date: start.addingTimeInterval(60)).value
        clock.now = start.addingTimeInterval(90)
        present(fake, id, clear: false)
        fake.status = .denied
        fake.added = []
        await history.remindNote(id: id, date: clock.now.addingTimeInterval(-10)).value
        XCTAssertEqual(catchUpAlerts(fake), [])
        fake.status = .authorized
        await history.reconcileReminders().value
        XCTAssertEqual(catchUpAlerts(fake), ["set while off"])
        fake.delivered = []
        await make(fake, clock).start().value
        XCTAssertEqual(catchUpAlerts(fake), ["set while off"])
        XCTAssertEqual(fake.accessRequests, 0)
    }

    // MARK: Over the cap, while running

    func testReminderBeyondTheCapAlertsWhileRunningWithoutAClick() async throws {
        let ids = try seed(100)
        let fake = FakeNotifications()
        let clock = TestClock(start)
        let timer = FakeReminderTimer()
        let history = make(fake, clock, timer: timer)
        await history.start().value
        XCTAssertEqual(fake.pending.count, 60)
        XCTAssertEqual(timer.armedAt, start.addingTimeInterval(60 + DictationHistory.reminderWakeDelay))
        // The Mac slept through 65 minutes. macOS delivered the 60 requests it held and nobody clicked.
        clock.now = start.addingTimeInterval(65 * 60 + 30)
        for index in 0..<60 { present(fake, ids[index], clear: index.isMultiple(of: 2)) }
        fake.added = []
        await wake(history, timer)
        XCTAssertEqual(catchUpAlerts(fake), ["5 reminders are due"], "VoiceApp was running, so it must not say it was closed")
        XCTAssertEqual(Set(fake.pending.keys), Set((65..<100).map { NoteNotification.identifier(for: ids[$0], due: start.addingTimeInterval(Double($0 + 1) * 60)) }))
        XCTAssertEqual(timer.armedAt, start.addingTimeInterval(66 * 60 + DictationHistory.reminderWakeDelay))
        await wake(history, timer)
        XCTAssertEqual(catchUpAlerts(fake).count, 1)
        await make(fake, clock).start().value
        await make(fake, clock).start().value
        XCTAssertEqual(catchUpAlerts(fake).count, 1)
    }

    func testSingleReminderBeyondTheCapAlertsWithItsOwnText() async throws {
        let ids = try seed(61, spacing: 1)
        let fake = FakeNotifications()
        let clock = TestClock(start)
        let timer = FakeReminderTimer()
        let history = make(fake, clock, timer: timer)
        await history.start().value
        XCTAssertNil(key(ids[60], in: fake.pending.keys))
        clock.now = start.addingTimeInterval(61.5)
        for index in 0..<60 { present(fake, ids[index], clear: false) }
        fake.added = []
        await wake(history, timer)
        XCTAssertEqual(catchUpAlerts(fake), ["reminder 60"])
    }

    func testADeliveryAlsoAlertsForAReminderBeyondTheCapThatIsDue() async throws {
        let ids = try seed(61, spacing: 1)
        let fake = FakeNotifications()
        let clock = TestClock(start)
        let history = make(fake, clock)
        await history.start().value
        clock.now = start.addingTimeInterval(61.5)
        for index in 0..<60 { present(fake, ids[index], clear: false) }
        fake.added = []
        // The app is frontmost, so macOS tells it about one delivery. No timer has fired.
        await history.reminderDidAlert(id: ids[0]).value
        XCTAssertEqual(catchUpAlerts(fake), ["reminder 60"])
    }

    func testEveryDeliveryTopsUpWithoutRereadingOrResubmittingTheWindow() async throws {
        let ids = try seed(100)
        let fake = FakeNotifications()
        let clock = TestClock(start)
        let timer = FakeReminderTimer()
        let history = make(fake, clock, timer: timer)
        await history.start().value
        for step in 1...100 {
            clock.now = start.addingTimeInterval(Double(step) * 60 + 1)
            present(fake, ids[step - 1], clear: step.isMultiple(of: 3))
            fake.added = []
            await wake(history, timer)
            XCTAssertEqual(catchUpAlerts(fake), [], "macOS delivered step \(step); VoiceApp must not alert again")
            XCTAssertLessThanOrEqual(fake.added.count, 1, "only the freed slot is filled at step \(step)")
            XCTAssertLessThanOrEqual(fake.pending.count, NoteReminderScheduler.pendingLimit)
            XCTAssertEqual(fake.pending.count, min(60, 100 - step))
        }
        XCTAssertNil(timer.armedAt)
        await history.refreshNotes()
        XCTAssertTrue(history.notes.allSatisfy { $0.reminderNotifiedAt != nil })
    }

    func testEditsOnlyTouchTheNotificationsTheyChange() async throws {
        _ = try seed(100)
        let store = try MemoryStore(directory: directory)
        let plain = try store.append(kind: .note, rawText: "plain")
        try store.close()
        let fake = FakeNotifications()
        let clock = TestClock(start)
        let history = make(fake, clock)
        await history.start().value
        await history.refreshNotes()
        let remindedID = try XCTUnwrap(history.notes.first { $0.reminderScheduledFor != nil }).id
        fake.added = []
        fake.queries = 0
        await history.editNote(id: plain.id, text: "plain, edited").value
        await history.setNoteDone(id: plain.id, isDone: true).value
        XCTAssertEqual(fake.added.count, 0)
        XCTAssertEqual(fake.queries, 0, "a note without a reminder never reaches the notification center")
        await history.editNote(id: remindedID, text: "edited reminder").value
        XCTAssertEqual(fake.added.map(\.text), ["edited reminder"], "one request replaced, not sixty")
    }

    func testTimerFollowsTheNextDueTimeAndStopsWhenNothingIsDue() async throws {
        let fake = FakeNotifications()
        let clock = TestClock(start)
        let timer = FakeReminderTimer()
        let history = make(fake, clock, timer: timer)
        let id = await newNote(history, "timer")
        XCTAssertNil(timer.armedAt)
        await history.remindNote(id: id, date: start.addingTimeInterval(3600)).value
        XCTAssertEqual(timer.armedAt, start.addingTimeInterval(3600 + DictationHistory.reminderWakeDelay))
        await history.removeNoteReminder(id: id).value
        XCTAssertNil(timer.armedAt)
        await history.remindNote(id: id, date: start.addingTimeInterval(3600)).value
        fake.status = .denied
        await history.reconcileReminders().value
        XCTAssertNil(timer.armedAt, "nothing can alert while notifications are off")
    }

    func testTimeZoneAndClockChangesResubmitEveryPendingRequest() async throws {
        _ = try seed(3)
        let fake = FakeNotifications()
        let clock = TestClock(start)
        let events = NotificationCenter()
        let history = make(fake, clock, events: events)
        await history.start().value
        for name in [Notification.Name.NSSystemTimeZoneDidChange, .NSSystemClockDidChange] {
            fake.added = []
            events.post(name: name, object: nil)
            for _ in 0..<20 where fake.added.count < 3 { try await Task.sleep(for: .milliseconds(50)) }
            await history.pendingSave?.value
            XCTAssertEqual(fake.added.count, 3, "\(name.rawValue) moves wall-clock triggers")
        }
    }

    // MARK: Notifications off at the due time

    func testReminderDueWhileNotificationsWereOffAlertsOnceWhenTheyAreBackOn() async throws {
        let fake = FakeNotifications()
        let clock = TestClock(start)
        let history = make(fake, clock)
        let id = await newNote(history, "denied at due")
        await history.remindNote(id: id, date: start.addingTimeInterval(600)).value
        XCTAssertNotNil(key(id, in: fake.pending.keys))
        fake.status = .denied
        clock.now = start.addingTimeInterval(900)
        fake.pending = [:] // macOS shows nothing while notifications are off
        await make(fake, clock).start().value
        XCTAssertEqual(catchUpAlerts(fake), [])
        fake.status = .authorized
        fake.added = []
        await make(fake, clock).start().value
        XCTAssertEqual(catchUpAlerts(fake), ["denied at due"], "the user never saw it")
        await make(fake, clock).reconcileReminders(requestAuthorization: true).value
        fake.delivered = []
        await make(fake, clock).start().value
        XCTAssertEqual(catchUpAlerts(fake), ["denied at due"], "once, not on every launch")
        XCTAssertEqual(fake.accessRequests, 0)
    }

    func testNotificationsTurnedOffAcrossTheDueTimeWhileRunningAreCaughtUpAfterRefresh() async throws {
        let fake = FakeNotifications()
        let clock = TestClock(start)
        let timer = FakeReminderTimer()
        let history = make(fake, clock, timer: timer)
        let id = await newNote(history, "off while running")
        await history.remindNote(id: id, date: start.addingTimeInterval(600)).value
        fake.status = .denied
        fake.pending = [:]
        clock.now = start.addingTimeInterval(601)
        await wake(history, timer)
        XCTAssertTrue(history.reminderAccessDenied)
        fake.status = .authorized
        fake.added = []
        await history.reconcileReminders(requestAuthorization: true).value
        XCTAssertEqual(catchUpAlerts(fake), ["off while running"])
        await history.reconcileReminders(requestAuthorization: true).value
        XCTAssertEqual(catchUpAlerts(fake), ["off while running"])
    }

    func testDeliveredThenClearedReminderStillDoesNotAlertAgain() async throws {
        let fake = FakeNotifications()
        let clock = TestClock(start)
        let history = make(fake, clock)
        let id = await newNote(history, "cleared")
        await history.remindNote(id: id, date: start.addingTimeInterval(600)).value
        clock.now = start.addingTimeInterval(700)
        present(fake, id, clear: true)
        fake.added = []
        await make(fake, clock).start().value
        await make(fake, clock).start().value
        XCTAssertEqual(fake.added.count, 0)
    }

    // MARK: Triggers

    func testSubSecondDueTimeNeverFiresEarlyAndNearDueTimeStillFires() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let now = Date.now
        let later = now.addingTimeInterval(30.4)
        let calendar = try XCTUnwrap(SystemNoteNotificationCenter.request(
            for: NoteNotification(noteID: UUID(), text: "later", date: later), timeZone: zone, now: now).trigger as? UNCalendarNotificationTrigger)
        let fires = try XCTUnwrap(calendar.nextTriggerDate())
        XCTAssertGreaterThanOrEqual(fires, later, "a calendar trigger drops fractions, so round up")
        XCTAssertLessThan(fires.timeIntervalSince(later), 1)
        for offset in [0.2, 0.9, 1.0, 0, -5] {
            let near = now.addingTimeInterval(offset)
            let trigger = try XCTUnwrap(SystemNoteNotificationCenter.request(
                for: NoteNotification(noteID: UUID(), text: "near", date: near), timeZone: zone, now: now).trigger as? UNTimeIntervalNotificationTrigger,
                "a due time \(offset) s away can pass its second before the request lands")
            XCTAssertGreaterThanOrEqual(trigger.timeInterval, 1)
            XCTAssertLessThan(trigger.timeInterval, 3)
        }
    }
}
