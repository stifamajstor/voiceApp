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
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "main-store", withExtension: "sqlite", subdirectory: "Fixtures"))
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

    func testManualReminderUsesEditedTitleAndSelectedTimeAndUndoSurvivesRelaunch() async throws {
        let fake = FakeReminders()
        let history = makeHistory(reminders: fake)
        let completed = sample("Friday at nine is just text")
        await history.deliver(completed, destination: .note) { _ in XCTFail() }
        await history.pendingSave?.value
        XCTAssertTrue(fake.created.isEmpty, "Dates must not create reminders automatically")
        await history.editNote(id: completed.id, text: "Call Alex").value
        let date = Date(timeIntervalSince1970: 1_900_123_400)
        let create = history.remindNote(id: completed.id, date: date)
        let duplicate = history.remindNote(id: completed.id, date: date)
        await create.value
        await duplicate.value
        XCTAssertEqual(fake.created.map(\.title), ["Call Alex"])
        XCTAssertEqual(fake.created.map(\.date), [date])
        XCTAssertEqual(fake.accessRequests, 1)
        let store = try MemoryStore(directory: directory)
        let saved = try XCTUnwrap(store.notes().first)
        XCTAssertEqual(saved.reminderID, "reminder-1")
        XCTAssertEqual(saved.reminderDate, date)
        try store.close()
        let relaunched = makeHistory(reminders: fake)
        await relaunched.undoNoteReminder(id: completed.id).value
        XCTAssertEqual(fake.removed, ["reminder-1"])
        let reopened = try MemoryStore(directory: directory)
        XCTAssertNil(try reopened.notes().first?.reminderID)
        XCTAssertNil(try reopened.notes().first?.reminderDate)
        try reopened.close()
        await relaunched.undoNoteReminder(id: completed.id).value
        XCTAssertEqual(fake.removed.count, 1)
    }

    func testDeniedReminderPermissionExposesSettingsRecoveryAndCanRetry() async throws {
        let fake = FakeReminders()
        fake.granted = false
        let history = makeHistory(reminders: fake)
        let completed = sample("Call Alex")
        await history.deliver(completed, destination: .note) { _ in XCTFail() }
        await history.pendingSave?.value
        await history.remindNote(id: completed.id, date: .now).value
        XCTAssertTrue(history.reminderAccessDenied)
        XCTAssertTrue(try XCTUnwrap(history.noteError).contains("System Settings"))
        XCTAssertTrue(fake.created.isEmpty)
        XCTAssertNil(history.notes.first?.reminderID)
        fake.granted = true
        await history.remindNote(id: completed.id, date: .now).value
        XCTAssertFalse(history.reminderAccessDenied)
        XCTAssertNil(history.noteError)
        XCTAssertEqual(fake.created.count, 1)
        fake.granted = false
        await history.undoNoteReminder(id: completed.id).value
        XCTAssertEqual(history.notes.first?.reminderID, "reminder-1")
        XCTAssertTrue(fake.removed.isEmpty)
    }

    func testReminderFailuresKeepRetryableStateAndDeleteRequiresConfirmation() async throws {
        let fake = FakeReminders()
        let history = makeHistory(reminders: fake)
        let completed = sample("Call Alex")
        await history.deliver(completed, destination: .note) { _ in XCTFail() }
        await history.pendingSave?.value
        fake.failCreate = true
        await history.remindNote(id: completed.id, date: .now).value
        XCTAssertNotNil(history.noteError)
        XCTAssertNil(history.notes.first?.reminderID)
        fake.failCreate = false
        await history.remindNote(id: completed.id, date: .now).value
        fake.failRemove = true
        await history.undoNoteReminder(id: completed.id).value
        XCTAssertNotNil(history.noteError)
        XCTAssertEqual(history.notes.first?.reminderID, "reminder-1")
        XCTAssertNil(history.confirmDeleteNote())
        history.requestDeleteNote(try XCTUnwrap(history.notes.first))
        await history.confirmDeleteNote()?.value
        XCTAssertEqual(history.notes.count, 1)
        XCTAssertEqual(history.deleteFailures, 1)
        fake.failRemove = false
        history.requestDeleteNote(try XCTUnwrap(history.notes.first))
        await history.confirmDeleteNote()?.value
        XCTAssertTrue(history.notes.isEmpty)
        XCTAssertEqual(fake.removed, ["reminder-1"])
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
        let history = DictationHistory(repository: repository, defaults: defaults, log: { _ in })
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
        let fake = FakeReminders()
        let history = makeHistory(reminders: fake)
        let note = sample("linked note")
        await history.deliver(note, destination: .note) { _ in XCTFail() }
        await history.pendingSave?.value
        await history.remindNote(id: note.id, date: .now).value
        fake.failRemove = true
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

    func testFailedReminderLinkSaveCompensatesByRemovingCreatedReminder() async throws {
        let repository = GatedNotesRepository(directory: directory, failReminderLink: true)
        await repository.release()
        let fake = FakeReminders()
        let history = DictationHistory(repository: repository, reminders: fake, defaults: defaults, log: { _ in })
        let note = sample("call")
        await history.deliver(note, destination: .note) { _ in XCTFail() }
        await history.pendingSave?.value
        await history.remindNote(id: note.id, date: .now).value
        XCTAssertEqual(fake.removed, ["reminder-1"], history.noteError ?? "no error")
        XCTAssertNil(history.notes.first?.reminderID)
        XCTAssertNotNil(history.noteError)
    }

    private func makeHistory(reminders: FakeReminders? = nil) -> DictationHistory {
        DictationHistory(repository: SQLiteHistoryRepository(directory: directory), reminders: reminders ?? FakeReminders(),
                         defaults: defaults, log: { _ in })
    }

    private func sample(_ text: String) -> CompletedDictation {
        CompletedDictation(rawText: "raw \(text)", finalText: text, appBundleID: "com.apple.TextEdit",
                           appName: "TextEdit", modelID: "test-model", durationSeconds: 2)
    }
}

@MainActor
private final class FakeReminders: NoteReminderService {
    var granted = true
    var failCreate = false
    var failRemove = false
    var accessRequests = 0
    var created: [(title: String, date: Date)] = []
    var removed: [String] = []

    func requestAccess() async throws -> Bool { accessRequests += 1; return granted }
    func create(title: String, date: Date) throws -> String {
        if failCreate { throw ReminderError.noDefaultList }
        created.append((title, date))
        return "reminder-\(created.count)"
    }
    func remove(identifier: String) throws {
        if failRemove { throw CocoaError(.fileWriteNoPermission) }
        removed.append(identifier)
    }
}

private actor GatedNotesRepository: HistoryRepository {
    let entered = XCTestExpectation(description: "note append suspended")
    private let repository: SQLiteHistoryRepository
    private let failReminderLink: Bool
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    init(directory: URL, failReminderLink: Bool = false) {
        repository = SQLiteHistoryRepository(directory: directory)
        self.failReminderLink = failReminderLink
    }
    func open() async throws { try await repository.open() }
    func append(_ value: CompletedDictation) async throws -> MemoryRecord { try await repository.append(value) }
    func records(query: String, limit: Int) async throws -> [MemoryRecord] { try await repository.records(query: query, limit: limit) }
    func delete(ids: [UUID]) async throws { try await repository.delete(ids: ids) }
    func deleteAll() async throws { try await repository.deleteAll() }
    func appendNote(_ note: CompletedDictation) async throws {
        entered.fulfill()
        if !released { await withCheckedContinuation { continuation = $0 } }
        try await repository.appendNote(note)
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
    func notes(query: String, limit: Int) async throws -> [VoiceNote] { try await repository.notes(query: query, limit: limit) }
    func editNote(id: UUID, text: String) async throws { try await repository.editNote(id: id, text: text) }
    func setNoteDone(id: UUID, isDone: Bool) async throws { try await repository.setNoteDone(id: id, isDone: isDone) }
    func setNoteReminder(id: UUID, identifier: String?, date: Date?) async throws {
        if failReminderLink { throw CocoaError(.fileWriteNoPermission) }
        try await repository.setNoteReminder(id: id, identifier: identifier, date: date)
    }
}
