import Foundation
import XCTest
@testable import VoiceAppCore

private final class TestClock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}

/// The verification findings on PR #48 at eb6ea24 (probes P1, P1b, P3 and P4), one test each. They use only
/// calls that exist on that commit, so they run there too and fail there for the reason in each comment.
@MainActor
final class ReminderReviewFindingsTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var defaultsName: String!
    private let start = Date(timeIntervalSince1970: 1_900_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "ReminderFindings-\(UUID())")
        defaultsName = "ReminderFindings.\(UUID())"
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

    private func key(_ id: UUID, in identifiers: some Collection<String>) -> String? {
        identifiers.first { NoteNotification.noteID(for: $0) == id }
    }

    /// macOS shows the pending request at its due time. It counts as one alert the user saw. A click or
    /// Clear All then removes the delivered entry.
    private func present(_ fake: FakeNotifications, _ id: UUID, clear: Bool, shown: inout [String]) {
        guard let identifier = key(id, in: fake.pending.keys) else {
            return XCTFail("the request was not with macOS at its due time")
        }
        shown.append(identifier)
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

    /// P1. Notifications are off at the first reminder's due time and back on while VoiceApp runs. On
    /// eb6ea24 the timer was cancelled the moment it saw "off", so VoiceApp never woke for the next one.
    func testTimerKeepsRunningWhileNotificationsAreOffAndTheNextReminderStillWakesVoiceApp() async throws {
        let fake = FakeNotifications()
        let clock = TestClock(start)
        let timer = FakeReminderTimer()
        let history = make(fake, clock, timer: timer)
        let a = await newNote(history, "A")
        let b = await newNote(history, "B")
        await history.remindNote(id: a, date: start.addingTimeInterval(600)).value
        await history.remindNote(id: b, date: start.addingTimeInterval(3600)).value
        fake.status = .denied
        fake.pending[NoteNotification.identifier(for: a, due: start.addingTimeInterval(600))] = nil // not shown
        clock.now = start.addingTimeInterval(601)
        await wake(history, timer)
        XCTAssertTrue(history.reminderAccessDenied)
        XCTAssertEqual(timer.armedAt, start.addingTimeInterval(3600 + DictationHistory.reminderWakeDelay),
                       "off at A's due time must not stop the wake-up for B")
        fake.status = .authorized
        clock.now = start.addingTimeInterval(3601)
        var shown: [String] = []
        present(fake, b, clear: false, shown: &shown) // macOS shows B, nobody clicks
        fake.added = []
        await wake(history, timer)
        XCTAssertEqual(shown.count, 1)
        XCTAssertEqual(catchUpAlerts(fake), [], "B alerted once by macOS; A was with macOS at its due time")
        XCTAssertFalse(history.reminderAccessDenied, "the wake saw notifications on again, so Notes stops saying they are off")
        XCTAssertNil(timer.armedAt, "nothing is left to wait for")
    }

    /// P1b. 61 reminders a minute apart, notifications off at the first due time only. The 61st was never
    /// handed to macOS on eb6ea24 because nothing woke VoiceApp to top the window up.
    func testReminderBeyondTheCapStillAlertsAfterNotificationsWereOffAtTheFirstDueTime() async throws {
        let store = try MemoryStore(directory: directory)
        var ids: [UUID] = []
        for index in 0..<61 {
            let note = try store.append(kind: .note, rawText: "r\(index)")
            try store.setNoteReminder(id: note.id, date: start.addingTimeInterval(Double(index + 1) * 60))
            ids.append(note.id)
        }
        try store.close()
        let fake = FakeNotifications()
        let clock = TestClock(start)
        let timer = FakeReminderTimer()
        let history = make(fake, clock, timer: timer)
        await history.start().value
        XCTAssertNil(key(ids[60], in: fake.pending.keys), "behind 60 earlier reminders")
        var shown: [String] = []
        fake.status = .denied // off across the first due time only
        clock.now = start.addingTimeInterval(61)
        fake.pending[try XCTUnwrap(key(ids[0], in: fake.pending.keys))] = nil
        await wake(history, timer)
        XCTAssertNotNil(timer.armedAt, "the timer survives VoiceApp seeing notifications off")
        fake.status = .authorized
        for index in 1..<60 { // macOS keeps delivering the 59 it holds, nobody clicks
            clock.now = start.addingTimeInterval(Double(index + 1) * 60 + 1)
            present(fake, ids[index], clear: false, shown: &shown)
            await wake(history, timer)
        }
        XCTAssertNotNil(key(ids[60], in: fake.pending.keys), "reminder 61 was handed to macOS once a slot was free and notifications were on")
        clock.now = start.addingTimeInterval(61 * 60 + 1)
        present(fake, ids[60], clear: false, shown: &shown) // macOS shows it at its due time
        fake.added = []
        await wake(history, timer)
        XCTAssertEqual(shown.filter { NoteNotification.noteID(for: $0) == ids[60] }.count, 1)
        XCTAssertEqual(Set(shown.compactMap(NoteNotification.noteID)), Set(ids[1...]), "each of the 60 shown once")
        XCTAssertEqual(shown.count, 60)
        clock.now = clock.now.addingTimeInterval(86_400)
        await wake(history, timer)
        await make(fake, clock).start().value
        XCTAssertEqual(catchUpAlerts(fake), [], "nothing is alerted a second time, not even after a relaunch")
    }

    /// P3. macOS showed the reminder while VoiceApp was closed and the user cleared it. Notifications are
    /// then turned off, VoiceApp launched, notifications turned on and Refresh pressed. eb6ea24 forgot the
    /// handoff at the launch that saw "off", so Refresh alerted a second time.
    func testShownWhileClosedThenOffAtLaunchThenOnDoesNotAlertASecondTime() async throws {
        let fake = FakeNotifications()
        let clock = TestClock(start)
        let history = make(fake, clock)
        let id = await newNote(history, "seen once")
        await history.remindNote(id: id, date: start.addingTimeInterval(600)).value
        var shown: [String] = []
        clock.now = start.addingTimeInterval(700)
        present(fake, id, clear: true, shown: &shown) // the user saw it and cleared it
        fake.status = .denied
        fake.added = []
        await make(fake, clock).start().value
        fake.status = .authorized
        await make(fake, clock).reconcileReminders(requestAuthorization: true, resubmit: .all).value
        XCTAssertEqual(shown.count + catchUpAlerts(fake).count, 1, "alerted twice for one due time")
        XCTAssertEqual(catchUpAlerts(fake), [])
    }

    /// P4. The reminder fired and was marked alerted. The clock is then set back 30 minutes. eb6ea24
    /// handed the same due time to macOS again, so it alerted a second time.
    func testClockSetBackAfterFiringDoesNotAlertTheSameDueTimeAgain() async throws {
        let fake = FakeNotifications()
        let clock = TestClock(start)
        let timer = FakeReminderTimer()
        let events = NotificationCenter()
        let history = make(fake, clock, timer: timer, events: events)
        let id = await newNote(history, "clock back")
        let due = start.addingTimeInterval(600)
        await history.remindNote(id: id, date: due).value
        var shown: [String] = []
        clock.now = due.addingTimeInterval(1)
        present(fake, id, clear: true, shown: &shown)
        await wake(history, timer)
        clock.now = due.addingTimeInterval(-1800)
        events.post(name: .NSSystemClockDidChange, object: nil)
        for _ in 0..<20 { try await Task.sleep(for: .milliseconds(20)) }
        await history.pendingSave?.value
        XCTAssertNil(key(id, in: fake.pending.keys), "an alerted reminder is not handed to macOS again for the same due time")
        clock.now = due.addingTimeInterval(1)
        if let again = key(id, in: fake.pending.keys) { shown.append(again); fake.pending[again] = nil }
        await wake(history, timer)
        await make(fake, clock).start().value
        XCTAssertEqual(shown.count, 1, "alerted twice for one due time after the clock moved back")
        XCTAssertEqual(catchUpAlerts(fake), [])
    }
}
