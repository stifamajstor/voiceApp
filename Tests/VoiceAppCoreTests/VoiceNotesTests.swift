import Foundation
import GRDB
@testable import VoiceAppCore
import XCTest

@MainActor
final class VoiceNotesTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var defaultsName: String!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "VoiceNotesTests-\(UUID())")
        defaultsName = "VoiceNotesTests.\(UUID())"
        defaults = UserDefaults(suiteName: defaultsName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: defaultsName)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    func testBothNoteShortcutRoutesStoreResultsWithoutPasting() async throws {
        let history = makeHistory()
        for trigger in [CaptureTrigger.notePushToTalk, .noteToggle] {
            await history.deliver(sample("shortcut note"), destination: trigger.destination) { _ in
                XCTFail("A note shortcut must never call insertion")
            }
        }
        await history.pendingSave?.value
        let store = try MemoryStore(directory: directory)
        XCTAssertEqual(try store.notes().count, 2)
        XCTAssertEqual(try store.count(kind: .dictation), 0)
        try store.close()
        for trigger in [CaptureTrigger.pushToTalk, .toggle] {
            var pasted = false
            await history.deliver(sample("dictation"), destination: trigger.destination) { _ in pasted = true }
            XCTAssertTrue(pasted)
        }
        await history.pendingSave?.value
    }

    func testNoteDeliveryNeverPastesEvenWithHistoryDisabledAndSurvivesReopen() async throws {
        let history = makeHistory()
        history.saveEnabled = false
        let completed = sample("buy milk")
        await history.deliver(completed, destination: .note) { _ in XCTFail("A note must never paste") }
        await history.pendingSave?.value
        let store = try MemoryStore(directory: directory)
        let note = try XCTUnwrap(store.notes().first)
        XCTAssertEqual(note.text, "buy milk")
        XCTAssertEqual(note.record.kind, .note)
        XCTAssertEqual(note.record.appName, "TextEdit")
        XCTAssertEqual(note.record.appBundleID, "com.apple.TextEdit")
        XCTAssertEqual(note.record.rawText, "raw buy milk")
        XCTAssertNil(note.record.audioPath)
        XCTAssertEqual(try store.count(kind: .dictation), 0)
        XCTAssertTrue(history.recent.isEmpty)
        XCTAssertEqual(history.noteFeedback, "Note saved")
        try store.close()
        let relaunched = makeHistory()
        await relaunched.refreshNotes()
        XCTAssertEqual(relaunched.notes.map(\.text), ["buy milk"])
    }

    func testEditDoneAndConfirmedDeletePersistWithoutMutatingOriginalTranscript() async throws {
        let history = makeHistory()
        let first = sample("old secret")
        let second = sample("keep this")
        await history.deliver(first, destination: .note) { _ in XCTFail() }
        await history.deliver(second, destination: .note) { _ in XCTFail() }
        await history.pendingSave?.value
        await history.editNote(id: first.id, text: "new wording").value
        await history.setNoteDone(id: first.id, isDone: true).value
        let store = try MemoryStore(directory: directory)
        let edited = try XCTUnwrap(store.notes().first { $0.id == first.id })
        XCTAssertTrue(edited.isDone)
        XCTAssertEqual(edited.text, "new wording")
        XCTAssertEqual(try store.fetch(id: first.id)?.finalText, "old secret")
        XCTAssertEqual(try store.notes(query: "new wor").map(\.id), [first.id])
        XCTAssertTrue(try store.notes(query: "old secret").isEmpty)
        try store.close()
        let reopened = makeHistory()
        await reopened.refreshNotes()
        XCTAssertEqual(reopened.notes.first { $0.id == first.id }, edited)
        reopened.requestDeleteNote(edited)
        reopened.cancelDeleteNote()
        XCTAssertNil(reopened.confirmDeleteNote())
        await reopened.refreshNotes()
        XCTAssertEqual(reopened.notes.count, 2)
        reopened.requestDeleteNote(edited)
        reopened.isNoteDeleteConfirmationPresented = false
        await reopened.confirmDeleteNote()?.value
        let afterDelete = try MemoryStore(directory: directory)
        XCTAssertNil(try afterDelete.fetch(id: first.id))
        XCTAssertNotNil(try afterDelete.tombstone(id: first.id))
        XCTAssertEqual(try afterDelete.notes().map(\.id), [second.id])
        try afterDelete.close()
        let db = try DatabaseQueue(path: directory.appending(path: "store.sqlite").path)
        let remainingState = try await db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM noteState WHERE recordID = ?", arguments: [first.id.uuidString]) }
        XCTAssertEqual(remainingState, 0)
        try db.close()
        let relaunched = makeHistory()
        await relaunched.refreshNotes()
        XCTAssertEqual(relaunched.notes.map(\.id), [second.id])
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where file.lastPathComponent.hasPrefix("store.sqlite") {
            let bytes = try Data(contentsOf: file)
            XCTAssertNil(bytes.range(of: Data("old secret".utf8)))
            XCTAssertNil(bytes.range(of: Data("new wording".utf8)))
        }
    }

    func testMigrationBackfillsExistingNotesAndPreservesOtherRecords() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "main-29e9eda-store", withExtension: "sqlite", subdirectory: "Fixtures"))
        let path = directory.appending(path: "store.sqlite")
        try FileManager.default.copyItem(at: fixture, to: path)
        let database = try DatabaseQueue(path: path.path)
        let id = UUID()
        try await database.write { db in
            try db.execute(sql: """
                INSERT INTO records (id, deviceID, kind, createdAt, rawText, finalText)
                VALUES (?, (SELECT deviceID FROM storeMetadata WHERE singleton = 1), 'note', 1, 'legacy raw', 'legacy final')
                """, arguments: [id.uuidString])
        }
        try database.close()
        let store = try MemoryStore(directory: directory)
        XCTAssertEqual(try store.note(id: id)?.text, "legacy final")
        XCTAssertEqual(try store.note(id: id)?.isDone, false)
        XCTAssertEqual(try store.notes(query: "legacy fin").map(\.id), [id])
        XCTAssertEqual(try store.listRecent(kind: .dictation).map(\.rawText), ["main migration survivor"])
        try store.editNote(id: id, text: "updated legacy note")
        try store.close()
        let reopened = try MemoryStore(directory: directory)
        XCTAssertEqual(try reopened.note(id: id)?.text, "updated legacy note")
        XCTAssertEqual(try reopened.fetch(id: id)?.finalText, "legacy final")
        try reopened.close()
    }

    func testMigrationPreservesEarlierDraftNoteStateAndDropsExternalIdentifier() async throws {
        let store = try MemoryStore(directory: directory)
        let active = try store.append(kind: .note, rawText: "original active")
        let done = try store.append(kind: .note, rawText: "original done")
        try store.close()
        let database = try DatabaseQueue(path: directory.appending(path: "store.sqlite").path)
        try await database.write { db in
            let triggers = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'trigger' AND tbl_name = 'noteState'")
            for trigger in triggers { try db.execute(sql: "DROP TRIGGER \(trigger.quotedDatabaseIdentifier)") }
            try db.execute(sql: """
                DROP TABLE notesFTS;
                DROP TRIGGER notes_insert;
                DROP TRIGGER notes_delete;
                DROP TABLE noteState;
                CREATE TABLE noteState (
                    recordID TEXT PRIMARY KEY NOT NULL REFERENCES records(id), text TEXT NOT NULL,
                    isDone INTEGER NOT NULL DEFAULT 0 CHECK (isDone IN (0, 1)),
                    reminderID TEXT, reminderDate REAL,
                    CHECK ((reminderID IS NULL) = (reminderDate IS NULL))
                );
                INSERT INTO noteState (recordID, text, isDone, reminderID, reminderDate)
                    SELECT id, 'edited ' || rawText, CASE WHEN rawText = 'original done' THEN 1 ELSE 0 END,
                        'old-external-id', 1900000000 FROM records WHERE kind = 'note';
                CREATE TRIGGER notes_insert AFTER INSERT ON records WHEN NEW.kind = 'note'
                BEGIN INSERT INTO noteState (recordID, text) VALUES (NEW.id, NEW.finalText); END;
                CREATE TRIGGER notes_delete AFTER UPDATE ON records WHEN NEW.deletedAt IS NOT NULL
                BEGIN DELETE FROM noteState WHERE recordID = NEW.id; END;
                DELETE FROM grdb_migrations WHERE identifier IN ('notes.localReminders', 'notes.reminderHandoff');
                """)
            try db.create(virtualTable: "notesFTS", using: FTS5()) { table in
                table.synchronize(withTable: "noteState")
                table.tokenizer = .unicode61()
                table.column("text")
            }
        }
        try database.close()
        let migrated = try MemoryStore(directory: directory)
        XCTAssertEqual(try migrated.note(id: active.id)?.text, "edited original active")
        XCTAssertEqual(try migrated.note(id: active.id)?.reminderDate, Date(timeIntervalSince1970: 1_900_000_000))
        XCTAssertNil(try migrated.note(id: active.id)?.reminderNotifiedAt)
        XCTAssertEqual(try migrated.note(id: done.id)?.isDone, true)
        XCTAssertNil(try migrated.note(id: done.id)?.reminderDate)
        XCTAssertEqual(try migrated.notes(query: "edited original act").map(\.id), [active.id])
        try migrated.close()
    }

    func testEmptyEditFailsAndMarkUndonePersists() async throws {
        let history = makeHistory()
        let completed = sample("keep text")
        await history.deliver(completed, destination: .note) { _ in XCTFail() }
        await history.pendingSave?.value
        await history.editNote(id: completed.id, text: " \n ").value
        XCTAssertNotNil(history.noteError)
        await history.setNoteDone(id: completed.id, isDone: true).value
        await history.setNoteDone(id: completed.id, isDone: false).value
        let store = try MemoryStore(directory: directory)
        let note = try XCTUnwrap(store.notes().first)
        XCTAssertEqual(note.text, "keep text")
        XCTAssertFalse(note.isDone)
        try store.close()
    }

    func testEditReportsItsOwnFailureEvenWhenALaterSaveClearsTheGlobalError() async throws {
        let history = makeHistory()
        let note = sample("original")
        await history.deliver(note, destination: .note) { _ in XCTFail() }
        await history.pendingSave?.value
        var editFailure: String?
        let edited = expectation(description: "edit completion")
        history.editNote(id: note.id, text: " ") { error in
            editFailure = error
            edited.fulfill()
        }
        await history.deliver(sample("later note"), destination: .note) { _ in XCTFail() }
        await history.pendingSave?.value
        await fulfillment(of: [edited], timeout: 2)
        XCTAssertNotNil(editFailure)
        XCTAssertNil(history.noteError)
        XCTAssertEqual(history.notes.first { $0.id == note.id }?.text, "original")
    }

    func testSetRemoveEditDoneAndDeleteReconcilePendingNotifications() async throws {
        let fake = FakeNotifications()
        fake.status = .notDetermined
        let history = makeHistory(notifications: fake)
        let note = sample("Friday at nine is just text")
        await history.deliver(note, destination: .note) { _ in XCTFail() }
        await history.pendingSave?.value
        XCTAssertTrue(fake.pending.isEmpty)
        XCTAssertEqual(fake.accessRequests, 0)
        let date = Date(timeIntervalSince1970: 1_900_000_000)
        let identifier = NoteNotification.identifier(for: note.id)
        await history.remindNote(id: note.id, date: date).value
        XCTAssertEqual(fake.accessRequests, 1)
        XCTAssertEqual(fake.pending[identifier]?.text, note.finalText)
        XCTAssertEqual(fake.pending[identifier]?.date, date)
        XCTAssertEqual(history.notes.first?.reminderDate, date)
        await history.remindNote(id: note.id, date: date).value
        XCTAssertEqual(fake.pending.count, 1)
        XCTAssertEqual(fake.accessRequests, 1)
        await history.editNote(id: note.id, text: "Call Alex").value
        XCTAssertEqual(fake.pending[identifier]?.text, "Call Alex")
        await history.removeNoteReminder(id: note.id).value
        XCTAssertNil(fake.pending[identifier])
        XCTAssertNil(history.notes.first?.reminderDate)
        await history.remindNote(id: note.id, date: date).value
        await history.setNoteDone(id: note.id, isDone: true).value
        XCTAssertNil(fake.pending[identifier])
        XCTAssertNil(history.notes.first?.reminderDate)
        await history.setNoteDone(id: note.id, isDone: false).value
        XCTAssertTrue(fake.pending.isEmpty)
        await history.remindNote(id: note.id, date: date).value
        XCTAssertNil(history.confirmDeleteNote())
        XCTAssertNotNil(fake.pending[identifier])
        history.requestDeleteNote(try XCTUnwrap(history.notes.first))
        await history.confirmDeleteNote()?.value
        XCTAssertNil(fake.pending[identifier])
        XCTAssertTrue(history.notes.isEmpty)
        let store = try MemoryStore(directory: directory)
        XCTAssertNotNil(try store.tombstone(id: note.id))
        try store.close()
    }

    func testDeniedAuthorizationKeepsReminderInAppAcrossLaunchAndRemovalNeedsNoPermission() async throws {
        let fake = FakeNotifications()
        fake.status = .notDetermined
        fake.granted = false
        let history = makeHistory(notifications: fake)
        let note = sample("Call Alex")
        await history.deliver(note, destination: .note) { _ in XCTFail() }
        await history.pendingSave?.value
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        await history.remindNote(id: note.id, date: date).value
        XCTAssertTrue(history.reminderAccessDenied)
        XCTAssertEqual(history.notes.first?.reminderDate, date)
        XCTAssertTrue(try XCTUnwrap(history.notes.first).isOverdue(at: .now))
        XCTAssertTrue(fake.pending.isEmpty)
        XCTAssertEqual(fake.accessRequests, 1)
        let relaunched = makeHistory(notifications: fake)
        await relaunched.refreshNotes()
        XCTAssertEqual(relaunched.notes.first?.reminderDate, date)
        XCTAssertTrue(relaunched.reminderAccessDenied)
        XCTAssertEqual(fake.accessRequests, 1, "Launch must never request permission")
        await relaunched.removeNoteReminder(id: note.id).value
        XCTAssertNil(relaunched.notes.first?.reminderDate)
        XCTAssertEqual(fake.accessRequests, 1)
    }

    func testFiredClickedReminderDoesNotAlertOnRelaunch() async throws {
        try await assertScheduledReminderDoesNotRepeat(clickLaunchesApp: false)
    }

    func testClosedAcrossDueTimeClickColdLaunchDoesNotAlertAgain() async throws {
        try await assertScheduledReminderDoesNotRepeat(clickLaunchesApp: true)
    }

    private func assertScheduledReminderDoesNotRepeat(clickLaunchesApp: Bool) async throws {
        let fake = FakeNotifications()
        let clock = Date(timeIntervalSince1970: 1_900_000_000)
        var history: DictationHistory? = makeHistory(notifications: fake, now: { clock })
        let note = sample("buy milk")
        await history!.deliver(note, destination: .note) { _ in XCTFail("Notes never paste") }
        await history!.pendingSave?.value
        await history!.remindNote(id: note.id, date: clock.addingTimeInterval(600)).value
        let id = NoteNotification.identifier(for: note.id)
        XCTAssertNotNil(fake.pending[id])
        if clickLaunchesApp { history = nil }
        // macOS fires the request, then a click or Clear All removes its delivered entry.
        fake.pending[id] = nil
        fake.delivered.insert(id)
        fake.delivered.remove(id)
        history = nil
        fake.added = []
        let relaunched = makeHistory(notifications: fake, now: { clock.addingTimeInterval(3600) })
        await relaunched.start().value
        XCTAssertTrue(fake.added.isEmpty, "A successful OS handoff must suppress catch-up after click/clear")
        let twice = makeHistory(notifications: fake, now: { clock.addingTimeInterval(7200) })
        await twice.start().value
        XCTAssertTrue(fake.added.isEmpty)
    }

    func testHundredRemindersScheduleNearestSixtyAndTopUpAfterFireAndChanges() async throws {
        var clock = Date(timeIntervalSince1970: 1_900_000_000)
        let initial = clock
        let store = try MemoryStore(directory: directory)
        var ids: [UUID] = []
        for index in 0..<100 {
            let note = try store.append(kind: .note, rawText: "reminder \(index)")
            ids.append(note.id)
            try store.setNoteReminder(id: note.id, date: initial.addingTimeInterval(Double(index + 1) * 60))
        }
        try store.close()
        let fake = FakeNotifications()
        let history = makeHistory(notifications: fake, now: { clock })
        await history.start().value
        await history.refreshNotes()
        XCTAssertEqual(history.notes.count, 100, "Capped reminders remain in Notes")
        func pendingIDs(_ range: Range<Int>) -> Set<String> {
            Set(range.map { NoteNotification.identifier(for: ids[$0]) })
        }
        XCTAssertEqual(Set(fake.pending.keys), pendingIDs(0..<60))
        XCTAssertEqual(history.notes.filter { $0.reminderScheduledFor != nil }.count, 60)
        let fired = NoteNotification.identifier(for: ids[0])
        clock = initial.addingTimeInterval(60)
        fake.pending[fired] = nil
        fake.delivered.insert(fired)
        await history.reminderDidAlert(id: ids[0]).value
        XCTAssertEqual(Set(fake.pending.keys), pendingIDs(1..<61))
        await history.removeNoteReminder(id: ids[1]).value
        XCTAssertEqual(Set(fake.pending.keys), pendingIDs(2..<62))
        await history.setNoteDone(id: ids[2], isDone: true).value
        XCTAssertEqual(Set(fake.pending.keys), pendingIDs(3..<63))
        history.requestDeleteNote(try XCTUnwrap(history.notes.first { $0.id == ids[3] }))
        await history.confirmDeleteNote()?.value
        XCTAssertEqual(Set(fake.pending.keys), pendingIDs(4..<64))
        // Move a previously scheduled reminder outside the cap: cancel its handoff too.
        await history.remindNote(id: ids[4], date: initial.addingTimeInterval(100_000)).value
        XCTAssertEqual(Set(fake.pending.keys), pendingIDs(5..<65))
        XCTAssertNil(history.notes.first { $0.id == ids[4] }?.reminderScheduledFor)
        XCTAssertNotNil(history.notes.first { $0.id == ids[0] }?.reminderNotifiedAt)
    }

    func testOnlyNeverHandedOffRemindersBeyondCapCatchUpAfterClosedDelivery() async throws {
        let initial = Date(timeIntervalSince1970: 1_900_000_000)
        let store = try MemoryStore(directory: directory)
        for index in 0..<100 {
            let note = try store.append(kind: .note, rawText: "reminder \(index)")
            try store.setNoteReminder(id: note.id, date: initial.addingTimeInterval(Double(index + 1)))
        }
        try store.close()
        let fake = FakeNotifications()
        let history = makeHistory(notifications: fake, now: { initial })
        await history.start().value
        XCTAssertEqual(fake.pending.count, 60)
        fake.pending = [:] // OS delivered all scheduled requests while the app was closed; user cleared them.
        fake.added = []
        let relaunched = makeHistory(notifications: fake, now: { initial.addingTimeInterval(200) })
        await relaunched.start().value
        XCTAssertEqual(fake.added.count, 1)
        XCTAssertEqual(fake.added.first?.text, "40 reminders were due while VoiceApp was closed")
        await relaunched.refreshNotes()
        XCTAssertTrue(relaunched.notes.allSatisfy { $0.reminderNotifiedAt != nil })
    }

    func testThreeNeverScheduledOverdueRemindersProduceOneSummaryOnlyOnce() async throws {
        let clock = Date(timeIntervalSince1970: 1_900_000_000)
        let store = try MemoryStore(directory: directory)
        for text in ["first", "second", "third"] {
            let note = try store.append(kind: .note, rawText: text)
            try store.setNoteReminder(id: note.id, date: clock.addingTimeInterval(-60))
        }
        try store.close()
        let fake = FakeNotifications()
        let history = makeHistory(notifications: fake, now: { clock })
        await history.start().value
        XCTAssertEqual(fake.added.count, 1)
        XCTAssertEqual(fake.added.first?.text, "3 reminders were due while VoiceApp was closed")
        let reopened = try MemoryStore(directory: directory)
        XCTAssertTrue(try reopened.notes().allSatisfy { $0.reminderNotifiedAt != nil })
        try reopened.close()
        fake.added = []
        fake.delivered = []
        let twice = makeHistory(notifications: fake, now: { clock })
        await twice.start().value
        XCTAssertTrue(fake.added.isEmpty)
    }

    func testLaunchReschedulesFutureRemindersAndCatchesUpOverdueOnlyOnce() async throws {
        let fake = FakeNotifications()
        let clock = Date(timeIntervalSince1970: 1_900_000_000)
        let history = makeHistory(notifications: fake, now: { clock })
        let future = sample("future")
        let overdue = sample("missed while closed")
        await history.deliver(future, destination: .note) { _ in XCTFail() }
        await history.deliver(overdue, destination: .note) { _ in XCTFail() }
        await history.pendingSave?.value
        await history.remindNote(id: future.id, date: clock.addingTimeInterval(3600)).value
        fake.failAdd = true
        await history.remindNote(id: overdue.id, date: clock.addingTimeInterval(60)).value
        fake.failAdd = false
        fake.pending = [:]
        fake.added = []
        let orphan = UUID()
        let orphanRequest = NoteNotification(noteID: orphan, text: "deleted", date: clock)
        fake.pending[orphanRequest.identifier] = orphanRequest
        let afterDue = clock.addingTimeInterval(120)
        let relaunched = makeHistory(notifications: fake, now: { afterDue })
        await relaunched.start().value
        await relaunched.refreshNotes()
        let futureID = NoteNotification.identifier(for: future.id)
        let overdueID = NoteNotification.identifier(for: overdue.id)
        XCTAssertEqual(fake.pending[futureID]?.date, clock.addingTimeInterval(3600))
        XCTAssertEqual(fake.added.filter { $0.identifier == overdueID }.count, 1)
        XCTAssertNil(fake.added.first { $0.identifier == overdueID }?.date)
        XCTAssertTrue(try XCTUnwrap(relaunched.notes.first { $0.id == overdue.id }).isOverdue(at: afterDue))
        XCTAssertNotNil(relaunched.notes.first { $0.id == overdue.id }?.reminderNotifiedAt)
        XCTAssertNil(fake.pending[orphanRequest.identifier])
        fake.delivered.remove(overdueID)
        let twice = makeHistory(notifications: fake, now: { afterDue })
        await twice.start().value
        XCTAssertEqual(fake.pending.count, 1)
        XCTAssertEqual(fake.added.filter { $0.identifier == overdueID }.count, 1)
        XCTAssertEqual(fake.accessRequests, 0)
    }

    func testLaunchDoesNotRepeatAnAlreadyDeliveredNotificationAndGrantCanRetry() async throws {
        let fake = FakeNotifications()
        let history = makeHistory(notifications: fake)
        let note = sample("delivered")
        await history.deliver(note, destination: .note) { _ in XCTFail() }
        await history.pendingSave?.value
        await history.remindNote(id: note.id, date: .now.addingTimeInterval(60)).value
        let identifier = NoteNotification.identifier(for: note.id)
        fake.delivered.insert(identifier)
        fake.pending = [:]
        fake.added = []
        let relaunched = makeHistory(notifications: fake, now: { .now.addingTimeInterval(120) })
        await relaunched.start().value
        XCTAssertTrue(fake.added.isEmpty)
        fake.status = .denied
        await relaunched.reconcileReminders().value
        XCTAssertTrue(relaunched.reminderAccessDenied)
        fake.status = .authorized
        await relaunched.reconcileReminders().value
        XCTAssertFalse(relaunched.reminderAccessDenied)
        await relaunched.removeNoteReminder(id: note.id).value
        XCTAssertFalse(fake.delivered.contains(identifier))
    }

    func testRefreshRequestsUnaskedPermissionButLaunchAndDeniedRefreshNeverPrompt() async throws {
        let clock = Date(timeIntervalSince1970: 1_900_000_000)
        let store = try MemoryStore(directory: directory)
        let note = try store.append(kind: .note, rawText: "allow notifications")
        try store.setNoteReminder(id: note.id, date: clock.addingTimeInterval(3600))
        try store.close()
        let fake = FakeNotifications()
        fake.status = .notDetermined
        let history = makeHistory(notifications: fake, now: { clock })
        await history.start().value
        XCTAssertEqual(fake.accessRequests, 0)
        XCTAssertEqual(history.reminderAuthorization, .notDetermined)
        XCTAssertTrue(history.reminderAuthorization.disclosure?.contains("not been asked yet") == true)
        await history.reconcileReminders(requestAuthorization: true).value
        XCTAssertEqual(fake.accessRequests, 1)
        XCTAssertEqual(fake.pending.count, 1)
        XCTAssertNil(history.reminderAuthorization.disclosure)
        fake.status = .denied
        await history.reconcileReminders(requestAuthorization: true).value
        XCTAssertEqual(fake.accessRequests, 1)
        XCTAssertTrue(history.reminderAccessDenied)
        XCTAssertTrue(history.reminderAuthorization.disclosure?.contains("turned off") == true)
    }

    func testNotificationFailureKeepsSavedReminderAndRetryRepairsIt() async throws {
        let fake = FakeNotifications()
        let history = makeHistory(notifications: fake)
        let note = sample("retry")
        await history.deliver(note, destination: .note) { _ in XCTFail() }
        await history.pendingSave?.value
        fake.failAdd = true
        let date = Date(timeIntervalSince1970: 1_900_000_000)
        await history.remindNote(id: note.id, date: date).value
        XCTAssertEqual(history.notes.first?.reminderDate, date)
        XCTAssertNotNil(history.notificationError)
        fake.failAdd = false
        await history.reconcileReminders().value
        XCTAssertNil(history.notificationError)
        XCTAssertNotNil(fake.pending[NoteNotification.identifier(for: note.id)])
    }

    func testReminderFilterAppliesBeforePaginationAndNotificationTargetEscapesFilters() async throws {
        let store = try MemoryStore(directory: directory)
        let target = try store.append(kind: .note, rawText: "old reminder")
        try store.setNoteReminder(id: target.id, date: .now.addingTimeInterval(3600))
        for index in 0..<105 { try store.append(kind: .note, rawText: "plain \(index)") }
        try store.close()
        let history = makeHistory()
        await history.refreshNotes()
        XCTAssertFalse(history.notes.contains { $0.id == target.id })
        history.remindersOnly = true
        await history.refreshNotes()
        XCTAssertEqual(history.notes.map(\.id), [target.id])
        XCTAssertFalse(history.hasMoreNotes)
        history.noteQuery = "no match"
        await history.openNote(id: target.id)
        XCTAssertEqual(history.focusedNoteID, target.id)
        XCTAssertTrue(history.notes.contains { $0.id == target.id })
        XCTAssertEqual(history.noteQuery, "")
        XCTAssertFalse(history.remindersOnly)
        XCTAssertEqual(history.notes.last?.id, target.id)
        await history.editNote(id: target.id, text: "edited old reminder").value
        XCTAssertEqual(history.notes.last?.id, target.id)
        XCTAssertEqual(history.notes.last?.text, "edited old reminder")
        XCTAssertEqual(NoteNotification.noteID(for: NoteNotification.identifier(for: target.id)), target.id)
        XCTAssertNil(NoteNotification.noteID(for: "another-feature"))
    }

    func testNewestFirstPrefixSearchHostileInputAndPagination() async throws {
        let store = try MemoryStore(directory: directory)
        let date = Date.now
        for index in 0..<105 {
            try store.append(kind: .note, createdAt: date, rawText: "note \(index) Straße")
        }
        try store.append(rawText: "dictation should not appear")
        try store.close()
        let history = makeHistory()
        await history.refreshNotes()
        XCTAssertEqual(history.notes.count, 100)
        XCTAssertTrue(history.hasMoreNotes)
        XCTAssertEqual(history.notes.first?.text, "note 104 Straße")
        await history.loadMoreNotes()
        XCTAssertEqual(history.notes.count, 105)
        XCTAssertFalse(history.hasMoreNotes)
        history.noteQuery = "104 str"
        await history.refreshNotes()
        XCTAssertEqual(history.notes.map(\.text), ["note 104 Straße"])
        history.noteQuery = "\" OR * :"
        await history.refreshNotes()
        XCTAssertTrue(history.notes.isEmpty)
        XCTAssertNil(history.noteError)
    }

    func testNoteQueueDoesNotDelayDictationAndQuitDrainsAcceptedWork() async throws {
        let repository = GatedNotesRepository(directory: directory)
        let history = DictationHistory(repository: repository, notifications: FakeNotifications(), defaults: defaults, log: { _ in })
        let note = sample("queued note")
        await history.deliver(note, destination: .note) { _ in XCTFail() }
        await fulfillment(of: [repository.entered], timeout: 2)
        var pasted = false
        await history.deliver(sample("dictation")) { _ in pasted = true }
        XCTAssertTrue(pasted)
        let termination = HistoryTermination(history: history)
        let quit = expectation(description: "queue drained")
        XCTAssertFalse(termination.requestTermination { success in
            XCTAssertTrue(success)
            quit.fulfill()
        })
        await repository.release()
        await fulfillment(of: [quit], timeout: 3)
        let store = try MemoryStore(directory: directory)
        XCTAssertEqual(try store.notes().map(\.text), ["queued note"])
        XCTAssertEqual(try store.listRecent(kind: .dictation).map(\.finalText), ["dictation"])
        try store.close()
    }

    func testFailedNoteDeletionCancelsQuitAndKeepsItsErrorAfterALaterSave() async throws {
        let fake = FakeNotifications()
        let repository = GatedNotesRepository(directory: directory, failDelete: true)
        await repository.release()
        let history = DictationHistory(repository: repository, notifications: fake, defaults: defaults, log: { _ in })
        let note = sample("linked note")
        await history.deliver(note, destination: .note) { _ in XCTFail() }
        await history.pendingSave?.value
        await history.remindNote(id: note.id, date: .now).value
        history.requestDeleteNote(try XCTUnwrap(history.notes.first))
        history.confirmDeleteNote()
        await history.deliver(sample("later note"), destination: .note) { _ in XCTFail() }
        let quit = expectation(description: "failed deletion cancels quit")
        let shown = expectation(description: "notes error brought forward")
        let termination = HistoryTermination(history: history, showHistory: { shown.fulfill() })
        XCTAssertFalse(termination.requestTermination { success in
            XCTAssertFalse(success)
            quit.fulfill()
        })
        await fulfillment(of: [quit, shown], timeout: 3)
        XCTAssertNotNil(history.noteDeleteError)
        XCTAssertEqual(history.notes.count, 2)
        XCTAssertFalse(termination.isQuitPending)
        XCTAssertNil(history.noteError)
    }

    func testFailedReminderSaveDoesNotScheduleNotification() async throws {
        let repository = GatedNotesRepository(directory: directory, failReminderLink: true)
        await repository.release()
        let fake = FakeNotifications()
        let history = DictationHistory(repository: repository, notifications: fake, defaults: defaults, log: { _ in })
        let note = sample("call")
        await history.deliver(note, destination: .note) { _ in XCTFail() }
        await history.pendingSave?.value
        await history.remindNote(id: note.id, date: .now).value
        XCTAssertTrue(fake.added.isEmpty)
        XCTAssertNil(history.notes.first?.reminderDate)
        XCTAssertNotNil(history.noteError)
    }

    func testDefaultDebounceSurvivesCancelledNoteSearch() async throws {
        let clock = Date.now
        let history = DictationHistory(repository: SQLiteHistoryRepository(directory: directory),
                                       notifications: FakeNotifications(), now: { clock }, defaults: defaults, log: { _ in })
        let note = sample("Call Alex")
        await history.deliver(note, destination: .note) { _ in XCTFail() }
        await history.pendingSave?.value
        for _ in 0..<20 {
            history.noteQuery = "Call"
            await Task.yield()
            try await Task.sleep(for: .milliseconds(10))
            history.noteQuery = ""
            await history.refreshNotes()
            await history.openNote(id: note.id)
            XCTAssertEqual(history.notes.map(\.id), [note.id])
            XCTAssertEqual(history.focusedNoteID, note.id)
            XCTAssertFalse(history.isSearchingNotes)
            XCTAssertNil(history.noteSearchError)
        }
    }

    private func makeHistory(notifications: FakeNotifications? = nil, now: @escaping () -> Date = { .now }) -> DictationHistory {
        DictationHistory(repository: SQLiteHistoryRepository(directory: directory), notifications: notifications ?? FakeNotifications(),
                         now: now, defaults: defaults, log: { _ in })
    }

    private func sample(_ text: String) -> CompletedDictation {
        CompletedDictation(rawText: "raw \(text)", finalText: text, appBundleID: "com.apple.TextEdit",
                           appName: "TextEdit", modelID: "test-model", durationSeconds: 2)
    }
}

@MainActor
final class FakeNotifications: NoteNotificationCenter {
    var status: NoteNotificationAuthorization = .authorized
    var granted = true
    var failAdd = false
    var accessRequests = 0
    var pending: [String: NoteNotification] = [:]
    var delivered: Set<String> = []
    var added: [NoteNotification] = []
    var onAdd: ((NoteNotification) -> Void)?

    func authorization() async -> NoteNotificationAuthorization { status }
    func requestAuthorization() async throws -> Bool {
        accessRequests += 1
        status = granted ? .authorized : .denied
        return granted
    }
    func pendingIdentifiers() async -> Set<String> { Set(pending.keys) }
    func deliveredIdentifiers() async -> Set<String> { delivered }
    func add(_ notification: NoteNotification) async throws {
        if failAdd { throw CocoaError(.fileWriteNoPermission) }
        added.append(notification)
        onAdd?(notification)
        if notification.date != nil { pending[notification.identifier] = notification }
        else { pending[notification.identifier] = nil; delivered.insert(notification.identifier) }
    }
    func remove(identifiers: Set<String>) {
        for id in identifiers { pending[id] = nil; delivered.remove(id) }
    }
}

private actor GatedNotesRepository: HistoryRepository {
    let entered = XCTestExpectation(description: "note append suspended")
    private let repository: SQLiteHistoryRepository
    private let failReminderLink: Bool
    private let failDelete: Bool
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    init(directory: URL, failReminderLink: Bool = false, failDelete: Bool = false) {
        repository = SQLiteHistoryRepository(directory: directory)
        self.failReminderLink = failReminderLink
        self.failDelete = failDelete
    }
    func open() async throws { try await repository.open() }
    func append(_ value: CompletedDictation) async throws -> MemoryRecord { try await repository.append(value) }
    func records(query: String, limit: Int) async throws -> [MemoryRecord] { try await repository.records(query: query, limit: limit) }
    func delete(ids: [UUID]) async throws {
        if failDelete { throw CocoaError(.fileWriteNoPermission) }
        try await repository.delete(ids: ids)
    }
    func deleteAll() async throws { try await repository.deleteAll() }
    func appendNote(_ note: CompletedDictation) async throws {
        entered.fulfill()
        if !released { await withCheckedContinuation { continuation = $0 } }
        try await repository.appendNote(note)
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
    func notes(query: String, remindersOnly: Bool, limit: Int) async throws -> [VoiceNote] {
        try await repository.notes(query: query, remindersOnly: remindersOnly, limit: limit)
    }
    func editNote(id: UUID, text: String) async throws { try await repository.editNote(id: id, text: text) }
    func setNoteDone(id: UUID, isDone: Bool) async throws { try await repository.setNoteDone(id: id, isDone: isDone) }
    func markNoteReminderScheduled(id: UUID, for date: Date?) async throws {
        try await repository.markNoteReminderScheduled(id: id, for: date)
    }
    func markNoteReminderNotified(id: UUID, at date: Date) async throws {
        try await repository.markNoteReminderNotified(id: id, at: date)
    }
    func setNoteReminder(id: UUID, date: Date?) async throws {
        if failReminderLink { throw CocoaError(.fileWriteNoPermission) }
        try await repository.setNoteReminder(id: id, date: date)
    }
}

// History-only doubles must fail if a test accidentally attempts notification persistence.
extension HistoryRepository {
    func markNoteReminderScheduled(id: UUID, for date: Date?) async throws {
        throw CocoaError(.featureUnsupported)
    }
}
