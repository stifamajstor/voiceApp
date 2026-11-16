import Foundation
import XCTest
@testable import VoiceAppCore

private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 &+ 1 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

private final class WorldClock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}

/// "Every reminder alerts exactly once for each due time it is set to", checked against random event
/// sequences. The simulated world is macOS (it shows a request at its due time while notifications are on
/// and drops it while they are off) around the real `DictationHistory`, a real store and the fake
/// notification center. The reference model below knows nothing about states or windows: it only counts
/// what the user saw for each time a reminder was set to.
@MainActor
private final class ReminderWorld {
    /// One time a reminder was set to. A re-set to the very same instant is a new one.
    struct SetTime {
        let note: UUID
        let due: Date
        let identifier: String
        let label: String
        var visible = 0
        /// macOS held the request at its due time while notifications were off, so it showed nothing.
        var droppedWhileOff = false
        /// The clock has been at or past the due time since it was set.
        var reached: Bool
        /// How many alerts it had when the reminder was removed, finished, deleted or set to another time.
        var visibleWhenEnded: Int?
    }

    static let limit = 3
    let seed: UInt64
    var generator: SeededGenerator
    let directory: URL
    let defaultsName: String
    let defaults: UserDefaults
    let fake = FakeNotifications()
    let clock = WorldClock(Date(timeIntervalSince1970: 1_900_000_000))
    var timer = FakeReminderTimer()
    var events = NotificationCenter()
    var wakeEvents = NotificationCenter()
    var history: DictationHistory!
    var running = true

    var sets: [SetTime] = []
    var current: [UUID: Int] = [:]
    var notes: [UUID] = []
    var doneNotes: Set<UUID> = []
    var gone: Set<UUID> = []
    var log: [String] = []
    var failure: String?
    var catchUps = 0

    init(seed: UInt64) {
        self.seed = seed
        generator = SeededGenerator(seed: seed)
        directory = FileManager.default.temporaryDirectory.appending(path: "ReminderWorld-\(seed)-\(UUID())")
        defaultsName = "ReminderWorld.\(UUID())"
        defaults = UserDefaults(suiteName: defaultsName)!
        fake.onAdd = { [unowned self] in self.didAdd($0) }
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: directory)
    }

    func fail(_ message: String) {
        if failure == nil { failure = message }
    }

    // MARK: The app under test

    func launch() async {
        timer = FakeReminderTimer()
        events = NotificationCenter()
        wakeEvents = NotificationCenter()
        let clock = clock
        history = DictationHistory(repository: SQLiteHistoryRepository(directory: directory), notifications: fake,
                                   notificationEvents: events, wakeEvents: wakeEvents, reminderTimer: timer,
                                   reminderLimit: Self.limit, now: { clock.now }, defaults: defaults,
                                   debounce: { _ in }, log: { _ in })
        running = true
        await history.start().value
        markReached()
    }

    private func waitForPass(after passes: Int) async {
        for _ in 0..<3000 where history.reminderPasses <= passes { try? await Task.sleep(for: .milliseconds(1)) }
        await history.pendingSave?.value
    }

    private func fireTimer() async {
        timer.fire()
        await history.pendingSave?.value
    }

    // MARK: The world: macOS and time

    /// macOS presents the request. It is shown only while notifications are on.
    private func macOSFires(_ request: NoteNotification, appIsRunning: Bool) async {
        let identifier = request.identifier
        fake.pending[identifier] = nil
        guard fake.status == .authorized else {
            if let index = sets.lastIndex(where: { $0.identifier == identifier }) { sets[index].droppedWhileOff = true }
            return
        }
        show(identifier)
        fake.delivered.insert(identifier)
        // Only while VoiceApp is frontmost does macOS tell it about a delivery.
        if appIsRunning, Bool.random(using: &generator) { await history.reminderDidAlert(requestID: identifier).value }
    }

    private func didAdd(_ notification: NoteNotification) {
        guard notification.date == nil else { return } // a request for later is not an alert
        catchUps += 1
        guard fake.status == .authorized else {
            return fail("an alert was posted while notifications are off: \(notification.text)")
        }
        if notification.noteID == nil {
            for covered in notification.covers { show(covered) }
        } else {
            show(notification.identifier)
        }
    }

    private func show(_ identifier: String) {
        guard let index = sets.lastIndex(where: { $0.identifier == identifier }) else {
            return fail("an alert for \(identifier) was shown but no reminder was set to that time")
        }
        sets[index].visible += 1
    }

    private func markReached() {
        for index in sets.indices where !sets[index].reached && sets[index].due <= clock.now { sets[index].reached = true }
    }

    /// Time passes. macOS fires requests and the reminder timer fires, in time order.
    func advance(by seconds: TimeInterval, appIsRunning: Bool = true) async {
        let target = clock.now.addingTimeInterval(seconds)
        while failure == nil {
            let nextRequest = fake.pending.values.filter { ($0.date ?? .distantFuture) <= target }.min { $0.date! < $1.date! }
            let nextTimer = appIsRunning ? timer.armedAt.flatMap { $0 <= target ? $0 : nil } : nil
            guard let moment = [nextRequest?.date, nextTimer].compactMap({ $0 }).min() else { break }
            clock.now = max(clock.now, moment)
            markReached()
            if let request = nextRequest, request.date == moment { await macOSFires(request, appIsRunning: appIsRunning) }
            else { await fireTimer() }
        }
        clock.now = target
        markReached()
    }

    /// The user sets the clock. VoiceApp first gets to notice everything macOS has shown: the second
    /// between macOS showing a reminder and the timer waking VoiceApp is a documented limit.
    private func setClock(to date: Date) async {
        await advance(by: 1.5)
        for _ in 0..<20 {
            guard let armed = timer.armedAt, armed.timeIntervalSince(clock.now) <= DictationHistory.reminderWakeDelay else { break }
            await advance(by: max(armed.timeIntervalSince(clock.now), 0.001))
        }
        let forward = date > clock.now
        clock.now = date
        markReached()
        if forward {
            while let request = fake.pending.values.filter({ ($0.date ?? .distantFuture) <= date }).min(by: { $0.date! < $1.date! }) {
                await macOSFires(request, appIsRunning: true)
            }
        }
        let passes = history.reminderPasses
        events.post(name: .NSSystemClockDidChange, object: nil)
        await waitForPass(after: passes)
        await advance(by: 0)
    }

    /// VoiceApp quits. macOS goes on holding its requests and showing them, with no callbacks.
    private func quit() {
        running = false
        history = nil
    }

    private func relaunch(closedFor seconds: TimeInterval) async {
        quit()
        await advance(by: seconds, appIsRunning: false)
        await launch()
        await advance(by: 0)
    }

    /// While VoiceApp is closed the world still moves: time passes, the user changes the notification
    /// settings or clears Notification Center, and sooner or later VoiceApp is opened again, sometimes by
    /// clicking a banner.
    private func closedStep() async {
        let roll = Int.random(in: 0..<100, using: &generator)
        switch roll {
        case 0..<20:
            log.append("(closed) notifications off")
            fake.status = .denied
        case 20..<45:
            log.append("(closed) notifications on")
            fake.status = .authorized
        case 45..<70:
            let seconds = [1.0, 30, 120, 4000, 90_000].randomElement(using: &generator)!
            log.append("(closed) time passes \(seconds)s")
            await advance(by: seconds, appIsRunning: false)
        case 70..<78:
            log.append("(closed) clear all delivered")
            fake.delivered = []
        default:
            log.append("launch")
            await launch()
            await advance(by: 0)
            if Bool.random(using: &generator),
               let identifier = fake.delivered.filter({ NoteNotification.noteID(for: $0) != nil }).sorted().randomElement(using: &generator) {
                log.append("(launched by a click on \(identifier.suffix(13)))")
                await history.reminderDidAlert(requestID: identifier).value
                fake.delivered.remove(identifier)
            }
        }
    }

    // MARK: The reference model

    private func end(_ note: UUID) {
        if let index = current.removeValue(forKey: note) { sets[index].visibleWhenEnded = sets[index].visible }
    }

    private func begin(_ note: UUID, due: Date) {
        end(note)
        sets.append(SetTime(note: note, due: due, identifier: NoteNotification.identifier(for: note, due: due),
                            label: "note \(notes.firstIndex(of: note) ?? -1) at +\(Int(due.timeIntervalSince(Date(timeIntervalSince1970: 1_900_000_000))))s",
                            reached: due <= clock.now))
        current[note] = sets.count - 1
    }

    // MARK: Operations

    private func pickNote(_ predicate: (UUID) -> Bool = { _ in true }) -> UUID? {
        let candidates = notes.filter { !gone.contains($0) && predicate($0) }
        return candidates.isEmpty ? nil : candidates[Int.random(in: 0..<candidates.count, using: &generator)]
    }

    func createNote() async {
        let dictation = CompletedDictation(rawText: "raw", finalText: "note \(notes.count)", appBundleID: nil, appName: nil,
                                           modelID: "test", durationSeconds: 1)
        await history.deliver(dictation, destination: .note) { _ in XCTFail("Notes never paste") }
        await history.pendingSave?.value
        notes.append(dictation.id)
        log.append("create note \(notes.count - 1)")
    }

    func step() async {
        guard running else {
            await closedStep()
            return checkInvariants()
        }
        let roll = Int.random(in: 0..<100, using: &generator)
        switch roll {
        case 0..<22: // set or re-set, sometimes to the time it already has
            guard let note = pickNote({ !doneNotes.contains($0) }) else { return }
            let offsets: [Double] = [-7200, -60, -1, 0, 1, 5, 30, 60, 90, 300, 3600, 7200, 86_400]
            var due = Date(timeIntervalSince1970: clock.now.timeIntervalSince1970.rounded(.down) + offsets.randomElement(using: &generator)!)
            if let existing = current[note], Int.random(in: 0..<5, using: &generator) == 0 { due = sets[existing].due }
            log.append("set note \(notes.firstIndex(of: note)!) to \(due.timeIntervalSince(Date(timeIntervalSince1970: 1_900_000_000)))s (now \(clock.now.timeIntervalSince(Date(timeIntervalSince1970: 1_900_000_000)))s, \(fake.status))")
            // The model first: an alert for a past time arrives during the call itself.
            begin(note, due: due)
            await history.remindNote(id: note, date: due).value
        case 22..<27:
            guard let note = pickNote() else { return }
            log.append("remove reminder of note \(notes.firstIndex(of: note)!)")
            end(note)
            await history.removeNoteReminder(id: note).value
        case 27..<32:
            guard let note = pickNote({ !doneNotes.contains($0) }) else { return }
            log.append("edit note \(notes.firstIndex(of: note)!)")
            await history.editNote(id: note, text: "edited \(Int.random(in: 0..<1000, using: &generator))").value
        case 32..<35:
            guard let note = pickNote({ !doneNotes.contains($0) }) else { return }
            log.append("done note \(notes.firstIndex(of: note)!)")
            end(note)
            await history.setNoteDone(id: note, isDone: true).value
            doneNotes.insert(note)
        case 35..<37:
            guard let note = pickNote({ doneNotes.contains($0) }) else { return }
            log.append("undone note \(notes.firstIndex(of: note)!)")
            await history.setNoteDone(id: note, isDone: false).value
            doneNotes.remove(note)
        case 37..<39:
            guard let note = pickNote() else { return }
            log.append("delete note \(notes.firstIndex(of: note)!)")
            await history.refreshNotes()
            guard let value = history.notes.first(where: { $0.id == note }) else { return }
            end(note)
            history.requestDeleteNote(value)
            await history.confirmDeleteNote()?.value
            gone.insert(note)
        case 39..<43:
            log.append("create note")
            if notes.count < 6 { await createNote() }
        case 43..<49:
            log.append("notifications off")
            fake.status = .denied
        case 49..<56:
            log.append("notifications on")
            fake.status = .authorized
        case 56..<76:
            let seconds = [0.5, 1, 2, 10, 30, 61, 120, 600, 3600, 7200, 86_400].randomElement(using: &generator)!
            log.append("time passes \(seconds)s")
            await advance(by: seconds)
        case 76..<80:
            let seconds = [60.0, 600, 3600].randomElement(using: &generator)!
            log.append("clock set forward \(seconds)s")
            await setClock(to: clock.now.addingTimeInterval(seconds + 1.5))
        case 80..<84:
            var target = clock.now.addingTimeInterval(-[60.0, 600, 1800, 7200].randomElement(using: &generator)!)
            // Often back to just before a reminder that already alerted, so its due time is ahead again.
            if Bool.random(using: &generator),
               let alerted = sets.filter({ $0.visible >= 1 && $0.due <= clock.now }).randomElement(using: &generator) {
                target = alerted.due.addingTimeInterval(-Double.random(in: 1...30, using: &generator).rounded())
            }
            log.append("clock set back to \(target.timeIntervalSince(Date(timeIntervalSince1970: 1_900_000_000)))s")
            await setClock(to: target)
        case 84..<86:
            log.append("time zone changes")
            let passes = history.reminderPasses
            events.post(name: .NSSystemTimeZoneDidChange, object: nil)
            await waitForPass(after: passes)
        case 86..<91:
            log.append("quit")
            quit()
        case 91..<93:
            log.append("refresh notifications")
            await history.reconcileReminders(requestAuthorization: true, resubmit: .all).value
        case 93..<96:
            guard let identifier = fake.delivered.filter({ NoteNotification.noteID(for: $0) != nil }).sorted().randomElement(using: &generator) else { return }
            log.append("click \(identifier.suffix(13))")
            await history.reminderDidAlert(requestID: identifier).value
            fake.delivered.remove(identifier)
        case 96..<98:
            log.append("clear all delivered")
            fake.delivered = []
        default:
            log.append("wake from sleep")
            let passes = history.reminderPasses
            wakeEvents.post(name: NSWorkspace.didWakeNotification, object: nil)
            await waitForPass(after: passes)
        }
        checkInvariants()
    }

    // MARK: Invariants

    func checkInvariants() {
        for set in sets {
            if set.visible > 1 { fail("\(set.label) alerted \(set.visible) times") }
            if let ended = set.visibleWhenEnded, set.visible != ended { fail("\(set.label) alerted after it was removed or replaced") }
            // A set that ended may share its identifier with the note's current one (re-set to the same instant).
            if set.visible >= 1, set.visibleWhenEnded == nil, fake.pending[set.identifier] != nil {
                fail("\(set.label) was handed to macOS again after it alerted")
            }
        }
        if fake.pending.count > Self.limit { fail("\(fake.pending.count) requests with macOS, more than the \(Self.limit) it may hold") }
        for identifier in Set(fake.pending.keys).union(fake.delivered) where NoteNotification.noteID(for: identifier) != nil {
            let note = NoteNotification.noteID(for: identifier)!
            guard let index = current[note], sets[index].identifier == identifier else {
                fail("\(identifier.suffix(13)) is in the notification center but is not the current time of a reminder")
                continue
            }
        }
        // While VoiceApp runs it must wake for every reminder whose due time was never reached,
        // whatever the notification settings are.
        let waiting = current.values.map { sets[$0] }.filter { !$0.reached }
        if running, let first = waiting.map(\.due).min() {
            if let armed = timer.armedAt {
                if armed > first.addingTimeInterval(DictationHistory.reminderWakeDelay + 0.001) {
                    fail("the timer waits until \(armed) but a reminder is due at \(first)")
                }
            } else {
                fail("no timer is armed although a reminder is due at \(first)")
            }
        }
    }

    /// After the user turns notifications on, lets all time pass and presses Refresh: every reminder that
    /// is still set has alerted exactly once, unless macOS held it while notifications were off. Nothing
    /// changes on relaunches.
    func finish() async {
        if !running {
            log.append("launch")
            await launch()
        }
        fake.status = .authorized
        log.append("settle: notifications on, ten days pass, Refresh")
        await advance(by: 10 * 86_400)
        await history.reconcileReminders(requestAuthorization: true, resubmit: .all).value
        await advance(by: 1)
        checkInvariants()
        for set in current.values.map({ sets[$0] }) {
            if set.visible == 0, !set.droppedWhileOff { fail("\(set.label) never alerted") }
            if set.visible > 1 { fail("\(set.label) alerted \(set.visible) times") }
        }
        let before = sets.map(\.visible)
        await relaunch(closedFor: 60)
        await relaunch(closedFor: 0)
        await history.reconcileReminders(requestAuthorization: true, resubmit: .all).value
        await advance(by: 3600)
        checkInvariants()
        if sets.map(\.visible) != before { fail("relaunching and refreshing alerted again: \(before) became \(sets.map(\.visible))") }
    }
}

@MainActor
final class ReminderInvariantTests: XCTestCase {
    private static var totals = (sets: 0, alerts: 0, dropped: 0, cancelled: 0, catchUps: 0, steps: 0)

    private var sequences: Int {
        ProcessInfo.processInfo.environment["REMINDER_FUZZ_SEQUENCES"].flatMap(Int.init) ?? 100
    }

    @discardableResult
    private func run(seed: UInt64, steps: Int) async -> Bool {
        let world = ReminderWorld(seed: seed)
        defer { world.cleanUp() }
        await world.launch()
        for _ in 0..<3 { await world.createNote() }
        var performed = 0
        while performed < steps, world.failure == nil {
            await world.step()
            performed += 1
        }
        if world.failure == nil { await world.finish() }
        Self.totals.sets += world.sets.count
        Self.totals.alerts += world.sets.map(\.visible).reduce(0, +)
        Self.totals.dropped += world.sets.filter(\.droppedWhileOff).count
        Self.totals.cancelled += world.sets.filter { $0.visibleWhenEnded != nil }.count
        Self.totals.catchUps += world.catchUps
        Self.totals.steps += world.log.count
        if let failure = world.failure {
            XCTFail("seed \(seed): \(failure)\nlast steps:\n" + world.log.suffix(45).joined(separator: "\n"))
            return false
        }
        return true
    }

    func testRandomEventSequencesAlertEveryReminderExactlyOncePerDueTimeItIsSetTo() async throws {
        // REMINDER_FUZZ_SEED=<n> replays one sequence.
        let seeds = ProcessInfo.processInfo.environment["REMINDER_FUZZ_SEED"].flatMap(UInt64.init).map { $0...$0 } ?? 1...UInt64(sequences)
        for seed in seeds where await !run(seed: seed, steps: 40) { break }
        let t = Self.totals
        print("RANDOM-RUN-SUMMARY sequences=\(sequences) steps=\(t.steps) setTimes=\(t.sets) alertsShown=\(t.alerts) catchUpsPosted=\(t.catchUps) droppedWhileOff=\(t.dropped) endedBeforeSettle=\(t.cancelled)")
    }
}
