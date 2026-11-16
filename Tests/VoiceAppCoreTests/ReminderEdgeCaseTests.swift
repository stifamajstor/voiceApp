import Foundation
import GRDB
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
                      events: NotificationCenter = NotificationCenter(),
                      wake: NotificationCenter = NotificationCenter()) -> DictationHistory {
        DictationHistory(repository: SQLiteHistoryRepository(directory: directory), notifications: fake,
                         notificationEvents: events, wakeEvents: wake, reminderTimer: timer ?? FakeReminderTimer(),
                         now: { clock.now }, defaults: defaults, debounce: { _ in }, log: { _ in })
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
        await history.reminderDidAlert(requestID: NoteNotification.identifier(for: ids[0], due: start.addingTimeInterval(1))).value
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
        XCTAssertTrue(history.notes.allSatisfy { $0.reminder.isAlerted })
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
        let remindedID = try XCTUnwrap(history.notes.first { $0.reminder.isHandedToMacOS }).id
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
        XCTAssertEqual(timer.armedAt, start.addingTimeInterval(3600 + DictationHistory.reminderWakeDelay),
                       "notifications being off decides whether a request can be added, never whether the timer runs")
        fake.status = .notDetermined
        await history.reconcileReminders().value
        XCTAssertNotNil(timer.armedAt)
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

    // MARK: Notifications off

    /// A request that was with macOS when its due time passed counts as alerted. Whether notifications
    /// were on at that moment cannot be told from a later look, and guessing it is what produced both zero
    /// and double alerts. The reminder stays in Notes as overdue.
    func testReminderMacOSHeldAtItsDueTimeCountsAsAlertedEvenIfNotificationsWereOff() async throws {
        let fake = FakeNotifications()
        let clock = TestClock(start)
        let history = make(fake, clock)
        let id = await newNote(history, "held while off")
        await history.remindNote(id: id, date: start.addingTimeInterval(600)).value
        XCTAssertNotNil(key(id, in: fake.pending.keys))
        fake.status = .denied
        clock.now = start.addingTimeInterval(900)
        fake.pending = [:] // macOS shows nothing while notifications are off
        await make(fake, clock).start().value
        fake.status = .authorized
        fake.added = []
        await make(fake, clock).start().value
        await make(fake, clock).reconcileReminders(requestAuthorization: true, resubmit: .all).value
        XCTAssertEqual(catchUpAlerts(fake), [], "no second alert for a due time macOS already had")
        XCTAssertEqual(fake.accessRequests, 0)
        let relaunched = make(fake, clock)
        await relaunched.refreshNotes()
        XCTAssertEqual(relaunched.notes.first?.reminder, .alerted(dueAt: start.addingTimeInterval(600)))
        XCTAssertTrue(try XCTUnwrap(relaunched.notes.first).isOverdue(at: clock.now), "Notes still shows it as overdue")
    }

    func testNotificationsOffAtTheDueTimeWhileRunningDoNotRepeatTheReminderAfterRefresh() async throws {
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
        await history.reconcileReminders(requestAuthorization: true, resubmit: .all).value
        XCTAssertEqual(catchUpAlerts(fake), [])
        XCTAssertFalse(history.reminderAccessDenied)
    }

    /// Never handed to macOS because notifications were off when it was set: one catch-up once they are on.
    func testReminderNeverHandedToMacOSBecauseNotificationsWereOffGetsOneCatchUp() async throws {
        let fake = FakeNotifications()
        fake.status = .denied
        let clock = TestClock(start)
        let timer = FakeReminderTimer()
        let history = make(fake, clock, timer: timer)
        let id = await newNote(history, "set while off")
        await history.remindNote(id: id, date: start.addingTimeInterval(600)).value
        XCTAssertTrue(fake.pending.isEmpty)
        XCTAssertEqual(timer.armedAt, start.addingTimeInterval(600 + DictationHistory.reminderWakeDelay))
        clock.now = start.addingTimeInterval(601)
        await wake(history, timer)
        XCTAssertEqual(catchUpAlerts(fake), [], "notifications are still off")
        XCTAssertNil(timer.armedAt)
        fake.status = .authorized
        await history.reconcileReminders().value
        XCTAssertEqual(catchUpAlerts(fake), ["set while off"])
        await history.reconcileReminders(resubmit: .all).value
        await make(fake, clock).start().value
        XCTAssertEqual(catchUpAlerts(fake), ["set while off"], "once, not on every launch")
        XCTAssertEqual(fake.accessRequests, 0)
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


    // MARK: Events that carry a due time

    func testADeliveryCallbackForAnEarlierDueTimeChangesNothing() async throws {
        let fake = FakeNotifications()
        let clock = TestClock(start)
        let history = make(fake, clock)
        let id = await newNote(history, "moved")
        let first = start.addingTimeInterval(600), second = start.addingTimeInterval(1200)
        await history.remindNote(id: id, date: first).value
        await history.remindNote(id: id, date: second).value
        await history.refreshNotes()
        XCTAssertEqual(history.notes.first?.reminder, .handedToMacOS(dueAt: second))
        // A late click on the banner of the time it was moved away from, and one from before due times were in identifiers.
        await history.reminderDidAlert(requestID: NoteNotification.identifier(for: id, due: first)).value
        await history.reminderDidAlert(requestID: "voice-note.\(id.uuidString)").value
        await history.reminderDidAlert(requestID: NoteNotification.summaryIdentifier).value
        await history.refreshNotes()
        XCTAssertEqual(history.notes.first?.reminder, .handedToMacOS(dueAt: second), "still waiting for its own due time")
        await history.reminderDidAlert(requestID: NoteNotification.identifier(for: id, due: second)).value
        await history.refreshNotes()
        XCTAssertEqual(history.notes.first?.reminder, .alerted(dueAt: second))
    }

    func testEachSetIsOneAlertEvenForTheTimeItAlreadyAlertedFor() async throws {
        let fake = FakeNotifications()
        let clock = TestClock(start.addingTimeInterval(100))
        let history = make(fake, clock)
        let id = await newNote(history, "again")
        let past = start.addingTimeInterval(50)
        await history.remindNote(id: id, date: past).value
        XCTAssertEqual(catchUpAlerts(fake), ["again"])
        await history.remindNote(id: id, date: past).value
        XCTAssertEqual(catchUpAlerts(fake), ["again", "again"], "the user set it again, so it is a new alert")
        await history.reconcileReminders(resubmit: .all).value
        await make(fake, clock).start().value
        XCTAssertEqual(catchUpAlerts(fake).count, 2)
    }

    func testTheSavedStateIsPerNoteAndSurvivesARelaunchUnchanged() async throws {
        let fake = FakeNotifications()
        let clock = TestClock(start)
        let history = make(fake, clock)
        let a = await newNote(history, "A")
        let b = await newNote(history, "B")
        await history.remindNote(id: a, date: start.addingTimeInterval(600)).value
        await history.remindNote(id: b, date: start.addingTimeInterval(1200)).value
        clock.now = start.addingTimeInterval(700)
        present(fake, a, clear: false)
        await history.reconcileReminders().value
        let relaunched = make(fake, clock)
        await relaunched.refreshNotes()
        let states = Dictionary(uniqueKeysWithValues: relaunched.notes.map { ($0.id, $0.reminder) })
        XCTAssertEqual(states[a], .alerted(dueAt: start.addingTimeInterval(600)))
        XCTAssertEqual(states[b], .handedToMacOS(dueAt: start.addingTimeInterval(1200)))
    }

    // MARK: Wake from sleep

    func testWakingFromSleepLooksAtTheRemindersAgainAndRearmsTheTimer() async throws {
        let fake = FakeNotifications()
        fake.status = .denied
        let clock = TestClock(start)
        let timer = FakeReminderTimer()
        let wake = NotificationCenter()
        let history = make(fake, clock, timer: timer, wake: wake)
        let slept = await newNote(history, "slept through")
        let later = await newNote(history, "later")
        await history.remindNote(id: slept, date: start.addingTimeInterval(600)).value
        await history.remindNote(id: later, date: start.addingTimeInterval(7200)).value
        XCTAssertEqual(timer.armedAt, start.addingTimeInterval(601))
        fake.status = .authorized
        timer.cancel() // the sleeping timer never woke VoiceApp
        clock.now = start.addingTimeInterval(3600)
        let before = history.reminderPasses
        wake.post(name: NSWorkspace.didWakeNotification, object: nil)
        for _ in 0..<200 where history.reminderPasses == before { try await Task.sleep(for: .milliseconds(5)) }
        await history.pendingSave?.value
        XCTAssertEqual(catchUpAlerts(fake), ["slept through"])
        XCTAssertEqual(timer.armedAt, start.addingTimeInterval(7200 + DictationHistory.reminderWakeDelay))
        XCTAssertNotNil(key(later, in: fake.pending.keys))
    }

    // MARK: Upgrade

    func testUpgradeFromTheTwoTimestampsKeepsWhatMacOSAlreadyHadAndCatchesUpOnlyTheRest() async throws {
        let store = try MemoryStore(directory: directory)
        let futureHanded = try store.append(kind: .note, rawText: "future handed").id
        let pastHanded = try store.append(kind: .note, rawText: "past handed").id
        let pastNeverHanded = try store.append(kind: .note, rawText: "past never handed").id
        let pastAlerted = try store.append(kind: .note, rawText: "past alerted").id
        let plain = try store.append(kind: .note, rawText: "plain").id
        try store.close()
        let future = start.addingTimeInterval(600), past = start.addingTimeInterval(-600)
        // The schema of the build before this one: two timestamps instead of one state.
        let database = try DatabaseQueue(path: directory.appending(path: "store.sqlite").path)
        try await database.write { db in
            try db.execute(sql: """
                ALTER TABLE noteState DROP COLUMN reminderPhase;
                ALTER TABLE noteState ADD COLUMN reminderNotifiedAt REAL;
                ALTER TABLE noteState ADD COLUMN reminderScheduledFor REAL;
                DELETE FROM grdb_migrations WHERE identifier = 'notes.reminderState';
                """)
            for (id, due, scheduled, notified) in [(futureHanded, future, future, nil), (pastHanded, past, past, nil),
                                                   (pastNeverHanded, past, nil, nil), (pastAlerted, past, nil, past)] as [(UUID, Date, Date?, Date?)] {
                try db.execute(sql: "UPDATE noteState SET reminderDate = ?, reminderScheduledFor = ?, reminderNotifiedAt = ? WHERE recordID = ?",
                               arguments: [due.timeIntervalSince1970, scheduled?.timeIntervalSince1970, notified?.timeIntervalSince1970, id.uuidString])
            }
        }
        try database.close()
        let migrated = try MemoryStore(directory: directory)
        XCTAssertEqual(try migrated.note(id: futureHanded)?.reminder, .handedToMacOS(dueAt: future))
        XCTAssertEqual(try migrated.note(id: pastHanded)?.reminder, .handedToMacOS(dueAt: past))
        XCTAssertEqual(try migrated.note(id: pastNeverHanded)?.reminder, .scheduled(dueAt: past))
        XCTAssertEqual(try migrated.note(id: pastAlerted)?.reminder, .alerted(dueAt: past))
        XCTAssertEqual(try migrated.note(id: plain)?.reminder, .idle)
        try migrated.close()
        // The old build named requests after the note alone. They are replaced, nothing alerts twice.
        let fake = FakeNotifications()
        let oldFuture = "voice-note.\(futureHanded.uuidString)"
        let oldPast = "voice-note.\(pastHanded.uuidString)"
        fake.pending[oldFuture] = NoteNotification(noteID: futureHanded, text: "future handed", date: future)
        fake.delivered.insert(oldPast)
        let clock = TestClock(start)
        let history = make(fake, clock)
        await history.start().value
        XCTAssertNil(fake.pending[oldFuture], "the request under the old identifier is removed")
        XCTAssertNotNil(fake.pending[NoteNotification.identifier(for: futureHanded, due: future)])
        XCTAssertEqual(catchUpAlerts(fake), ["past never handed"], "only the one macOS was never given")
        await history.refreshNotes()
        XCTAssertEqual(Set(history.notes.compactMap { $0.reminder.dueAt == nil ? nil : $0.id }), [futureHanded, pastHanded, pastNeverHanded, pastAlerted])
        XCTAssertTrue(history.notes.filter { $0.id != futureHanded && $0.reminder != .idle }.allSatisfy { $0.reminder.isAlerted })
        fake.added = []
        await make(fake, clock).start().value
        XCTAssertEqual(fake.added.filter { $0.date == nil }.count, 0)
    }

    func testSavingATransitionNeedsTheStateTheDecisionWasMadeFrom() throws {
        let store = try MemoryStore(directory: directory)
        defer { try? store.close() }
        let id = try store.append(kind: .note, rawText: "cas").id
        let due = start.addingTimeInterval(600)
        try store.setNoteReminder(id: id, date: due)
        XCTAssertEqual(try store.note(id: id)?.reminder, .scheduled(dueAt: due))
        XCTAssertTrue(try store.transitionNoteReminder(id: id, from: .scheduled(dueAt: due), to: .handedToMacOS(dueAt: due)))
        XCTAssertFalse(try store.transitionNoteReminder(id: id, from: .scheduled(dueAt: due), to: .missed(dueAt: due)),
                       "the note is no longer in that state")
        XCTAssertFalse(try store.transitionNoteReminder(id: id, from: .handedToMacOS(dueAt: due.addingTimeInterval(1)), to: .alerted(dueAt: due)),
                       "the note moved to another due time")
        XCTAssertEqual(try store.note(id: id)?.reminder, .handedToMacOS(dueAt: due))
        try store.setNoteDone(id: id, isDone: true)
        XCTAssertEqual(try store.note(id: id)?.reminder, .idle)
        try store.setNoteDone(id: id, isDone: false)
        XCTAssertEqual(try store.note(id: id)?.reminder, .idle, "marking undone does not bring the reminder back")
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
