import Foundation
import GRDB
@testable import VoiceAppCore
import XCTest

@MainActor
final class DictationHistoryTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var defaultsName: String!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defaultsName = "VoiceAppTests.\(UUID())"
        defaults = UserDefaults(suiteName: defaultsName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: defaultsName)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    func testDeliverySavesSnapshotAfterPasteAndSurvivesRelaunch() async throws {
        let repository = SQLiteHistoryRepository(directory: directory)
        let history = DictationHistory(repository: repository, defaults: defaults)
        await history.start().value
        let result = sample()
        var pasted: String?
        try await history.deliver(result) { text in
            pasted = text
            XCTAssertEqual(try self.records().count, 0)
        }
        XCTAssertEqual(pasted, result.finalText)
        await history.pendingSave?.value
        let saved = try XCTUnwrap(records().first)
        XCTAssertEqual(saved.kind, .dictation)
        XCTAssertEqual(saved.rawText, result.rawText)
        XCTAssertEqual(saved.finalText, result.finalText)
        XCTAssertEqual(saved.createdAt, result.createdAt)
        XCTAssertEqual(saved.appBundleID, "com.apple.TextEdit")
        XCTAssertEqual(saved.appName, "TextEdit")
        XCTAssertEqual(saved.modelID, "selected-model")
        XCTAssertEqual(saved.durationSeconds, 2.5)
        XCTAssertNil(saved.audioPath)
        let relaunched = DictationHistory(repository: SQLiteHistoryRepository(directory: directory), defaults: defaults)
        await relaunched.start().value
        XCTAssertEqual(relaunched.recent.map(\.text), [result.finalText])
    }

    func testDisabledHistoryPersistsPreferenceAndDoesNotWriteOrLoadStoredRecent() async throws {
        let store = try MemoryStore(directory: directory)
        try store.append(rawText: "stored")
        try store.close()
        let repository = SQLiteHistoryRepository(directory: directory)
        let history = DictationHistory(repository: repository, defaults: defaults)
        XCTAssertTrue(history.saveEnabled)
        history.saveEnabled = false
        await history.start().value
        XCTAssertTrue(history.recent.isEmpty)
        var pasted = false
        await history.deliver(sample()) { _ in pasted = true }
        await history.pendingSave?.value
        XCTAssertTrue(pasted)
        XCTAssertEqual(try records().map(\.rawText), ["stored"])
        XCTAssertEqual(history.recent.count, 1)
        let relaunched = DictationHistory(repository: repository, defaults: defaults)
        XCTAssertFalse(relaunched.saveEnabled)
    }

    func testUnavailableStoreStillPastesAndExposesReason() async throws {
        let repository = ControlledRepository()
        await repository.failOpen()
        let history = DictationHistory(repository: repository, defaults: defaults)
        await history.start().value
        XCTAssertEqual(history.storeError, "Test failure")
        var pasted = false
        await history.deliver(sample()) { _ in pasted = true }
        await history.pendingSave?.value
        XCTAssertTrue(pasted)
        XCTAssertEqual(history.recent.count, 1)
        let writes = await repository.writes
        XCTAssertTrue(writes.isEmpty)
    }

    func testSlowOpenNeverDelaysPasteAndDisabledPendingSaveIsDropped() async throws {
        let repository = ControlledRepository()
        let gate = Suspension()
        await repository.setOpenGate(gate)
        let history = DictationHistory(repository: repository, defaults: defaults)
        let opening = history.start()
        await fulfillment(of: [gate.entered], timeout: 2)
        var pasted = false
        await history.deliver(sample()) { _ in pasted = true }
        XCTAssertTrue(pasted)
        XCTAssertTrue(history.isOpening)
        history.saveEnabled = false
        await gate.release()
        await opening.value
        await history.pendingSave?.value
        let writes = await repository.writes
        XCTAssertTrue(writes.isEmpty)
    }

    func testSlowSaveNeverDelaysPasteOrAnotherDictation() async throws {
        let repository = ControlledRepository()
        let gate = Suspension()
        await repository.setSaveGate(gate)
        let history = DictationHistory(repository: repository, defaults: defaults)
        await history.start().value
        var pasted: [String] = []
        await history.deliver(sample("first")) { pasted.append($0) }
        await fulfillment(of: [gate.entered], timeout: 2)
        await history.deliver(sample("second")) { pasted.append($0) }
        XCTAssertEqual(pasted, ["first", "second"])
        await gate.release()
        await history.pendingSave?.value
        let writes = await repository.writes
        XCTAssertEqual(writes.map(\.finalText), ["first", "second"])
    }

    func testDisablingHistoryRejectsASaveWaitingForTheStore() async throws {
        let repository = ControlledRepository()
        let gate = Suspension()
        await repository.setSaveGate(gate)
        let history = DictationHistory(repository: repository, defaults: defaults)
        await history.start().value
        await history.deliver(sample()) { _ in }
        await fulfillment(of: [gate.entered], timeout: 2)
        history.saveEnabled = false
        await gate.release()
        await history.pendingSave?.value
        let writes = await repository.writes
        XCTAssertTrue(writes.isEmpty)
    }

    func testEnablingHistoryDuringPasteDoesNotSaveAPrivateDictation() async throws {
        let repository = ControlledRepository()
        let history = DictationHistory(repository: repository, defaults: defaults)
        history.saveEnabled = false
        await history.start().value
        await history.deliver(sample()) { _ in history.saveEnabled = true }
        await history.pendingSave?.value
        let writes = await repository.writes
        XCTAssertTrue(writes.isEmpty)
    }

    func testFailedSaveIsLoggedWithoutFailingPaste() async throws {
        let repository = ControlledRepository()
        await repository.failSave()
        var logs: [String] = []
        let history = DictationHistory(repository: repository, defaults: defaults, log: { logs.append($0) })
        await history.start().value
        var pasted = false
        await history.deliver(sample()) { _ in pasted = true }
        await history.pendingSave?.value
        XCTAssertTrue(pasted)
        XCTAssertEqual(logs.count, 1)
        XCTAssertEqual(history.saveError, "Test failure")
    }

    func testClipboardFallbackStillRetainsSuccessfulTranscription() async throws {
        let repository = ControlledRepository()
        let history = DictationHistory(repository: repository, defaults: defaults)
        await history.start().value
        do {
            try await history.deliver(sample()) { _ in throw TestFailure() }
            XCTFail("Paste error must still reach the dictation controller")
        } catch is TestFailure {}
        await history.pendingSave?.value
        let writes = await repository.writes
        XCTAssertEqual(writes.count, 1)
    }

    func testMenuClearDoesNotDeleteStoredRecordsOrResurrectThemOnRefresh() async throws {
        let repository = SQLiteHistoryRepository(directory: directory)
        let history = DictationHistory(repository: repository, defaults: defaults)
        await history.start().value
        for index in 0..<5 {
            await history.deliver(sample("entry \(index)")) { _ in }
            await history.pendingSave?.value
        }
        XCTAssertEqual(history.recent.map(\.text), ["entry 4", "entry 3", "entry 2"])
        history.clearRecent()
        await history.refreshRecent()
        XCTAssertTrue(history.recent.isEmpty)
        XCTAssertEqual(try records().count, 5)
        await history.deliver(sample("new")) { _ in }
        await history.pendingSave?.value
        XCTAssertEqual(history.recent.map(\.text), ["new"])
    }

    func testSearchUsesStorePrefixAndNewestFirstIncludingTimestampTies() async throws {
        let store = try MemoryStore(directory: directory)
        let older = try store.append(createdAt: Date(timeIntervalSince1970: 100), rawText: "hello world")
        _ = try store.append(kind: .note, rawText: "hello world")
        let newer = try store.append(createdAt: Date(timeIntervalSince1970: 200), rawText: "hello world again")
        let tie = try store.append(createdAt: newer.createdAt, rawText: "hello worldly")
        _ = try store.append(rawText: "hellos world")
        try store.close()
        let history = DictationHistory(repository: SQLiteHistoryRepository(directory: directory), defaults: defaults,
                                       debounce: { _ in })
        await history.start().value
        history.query = "hello wor"
        await history.pendingSearch?.value
        XCTAssertEqual(history.results, [tie, newer, older])
        XCTAssertFalse(history.isSearching)
        history.query = "   "
        await history.pendingSearch?.value
        XCTAssertEqual(history.results.count, 4)
    }

    func testSearchDebouncesAndDiscardsStaleResults() async throws {
        let repository = ControlledRepository()
        let debounce = Suspension()
        let history = DictationHistory(repository: repository, defaults: defaults, debounce: { _ in await debounce.enter() })
        await history.start().value
        await repository.resetQueries()
        history.query = "first"
        await fulfillment(of: [debounce.entered], timeout: 2)
        history.query = "latest"
        XCTAssertTrue(history.isSearching)
        let before = await repository.queries
        XCTAssertTrue(before.isEmpty)
        await debounce.release()
        await history.pendingSearch?.value
        let after = await repository.queries
        XCTAssertEqual(after, ["latest"])
        XCTAssertFalse(history.isSearching)
    }

    func testOlderInFlightSearchCannotReplaceNewerResultsOrClearBusyState() async throws {
        let repository = ControlledRepository()
        let gate = Suspension()
        await repository.setSearchGate(gate)
        let history = DictationHistory(repository: repository, defaults: defaults, debounce: { _ in })
        await history.start().value
        history.query = "old"
        await fulfillment(of: [gate.entered], timeout: 2)
        history.query = "new"
        let newest = history.pendingSearch
        await gate.release()
        await newest?.value
        XCTAssertEqual(history.results.map(\.finalText), ["new"])
        XCTAssertFalse(history.isSearching)
    }

    func testSelectedDeleteUsesOneBatchAndKeepsBusyUntilCompletion() async throws {
        let repository = ControlledRepository()
        let history = DictationHistory(repository: repository, defaults: defaults)
        await history.start().value
        await history.refresh()
        let selected = Set(history.results.map(\.id))
        history.selection = selected
        let gate = Suspension()
        await repository.setDeleteGate(gate)
        let deletion = Task { await history.deleteSelected() }
        await fulfillment(of: [gate.entered], timeout: 2)
        XCTAssertTrue(history.isDeleting)
        XCTAssertEqual(history.results.count, 2)
        await history.deleteSelected()
        await gate.release()
        await deletion.value
        XCTAssertFalse(history.isDeleting)
        XCTAssertTrue(history.results.isEmpty)
        XCTAssertTrue(history.selection.isEmpty)
        let batches = await repository.deletedBatches
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(Set(batches[0]), selected)
    }

    func testFailedDeleteRetainsResultsSelectionAndCanRetry() async throws {
        let repository = ControlledRepository()
        let history = DictationHistory(repository: repository, defaults: defaults)
        await history.start().value
        await history.refresh()
        history.selection = [try XCTUnwrap(history.results.first).id]
        let before = history.results
        let selected = history.selection
        await repository.failDelete(true)
        await history.deleteSelected()
        XCTAssertEqual(history.results, before)
        XCTAssertEqual(history.selection, selected)
        XCTAssertEqual(history.deleteError, "Test failure")
        XCTAssertFalse(history.isDeleting)
        await repository.failDelete(false)
        await history.deleteSelected()
        XCTAssertEqual(history.results.count, 1)
        XCTAssertNil(history.deleteError)
    }

    func testDeleteAllRequiresConfirmationAndDeletesBeyondVisibleSearchResults() async throws {
        let store = try MemoryStore(directory: directory)
        for index in 0..<105 { try store.append(rawText: "entry \(index)") }
        let note = try store.append(kind: .note, rawText: "keep note")
        try store.close()
        let history = DictationHistory(repository: SQLiteHistoryRepository(directory: directory), defaults: defaults,
                                       debounce: { _ in })
        await history.start().value
        await history.refresh()
        XCTAssertEqual(history.results.count, 100)
        XCTAssertTrue(history.hasMore)
        await history.loadMore()
        XCTAssertEqual(history.results.count, 105)
        history.query = "entry 1"
        await history.pendingSearch?.value
        await history.confirmDeleteAll()
        XCTAssertEqual(try records().count, 106)
        history.requestDeleteAll()
        history.cancelDeleteAll()
        await history.confirmDeleteAll()
        XCTAssertEqual(try records().count, 106)
        history.requestDeleteAll()
        await history.confirmDeleteAll()
        XCTAssertEqual(try records(), [note])
        XCTAssertTrue(history.results.isEmpty)
        XCTAssertTrue(history.recent.isEmpty)
        XCTAssertFalse(history.isDeleting)
    }

    func testSearchCompletionDoesNotHideDeleteFailure() async throws {
        let repository = ControlledRepository()
        let history = DictationHistory(repository: repository, defaults: defaults, debounce: { _ in })
        await history.start().value
        await history.refresh()
        history.selection = [try XCTUnwrap(history.results.first).id]
        await repository.failDelete(true)
        let gate = Suspension()
        await repository.setSearchGate(gate)
        history.query = "new search"
        await fulfillment(of: [gate.entered], timeout: 2)
        await history.deleteSelected()
        XCTAssertEqual(history.deleteError, "Test failure")
        await gate.release()
        await history.pendingSearch?.value
        XCTAssertEqual(history.deleteError, "Test failure")
    }

    func testLockedStoreSaveDoesNotDelayPasteOrMainActor() async throws {
        let repository = SQLiteHistoryRepository(directory: directory)
        let history = DictationHistory(repository: repository, defaults: defaults)
        await history.start().value
        var configuration = Configuration()
        configuration.allowsUnsafeTransactions = true
        let writer = try DatabaseQueue(path: directory.appending(path: "store.sqlite").path, configuration: configuration)
        defer { try? writer.close() }
        try writer.inDatabase { try $0.execute(sql: "BEGIN IMMEDIATE") }
        defer { try? writer.inDatabase { try $0.execute(sql: "ROLLBACK") } }
        let start = ContinuousClock.now
        var pasted = 0
        await history.deliver(sample("first")) { _ in pasted += 1 }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(history.saveError)
        await history.deliver(sample("second")) { _ in pasted += 1 }
        XCTAssertEqual(pasted, 2)
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        // The write timeout runs on the repository actor while this test continues on the main actor.
        await history.pendingSave?.value
        XCTAssertNotNil(history.saveError)
        XCTAssertEqual(try records().count, 0)
    }

    func testSearchFailureClearsBusyAndReportsError() async throws {
        let repository = ControlledRepository()
        let history = DictationHistory(repository: repository, defaults: defaults, debounce: { _ in })
        await history.start().value
        await repository.failSearch()
        history.query = "failure"
        await history.pendingSearch?.value
        XCTAssertFalse(history.isSearching)
        XCTAssertTrue(history.results.isEmpty)
        XCTAssertEqual(history.searchError, "Test failure")
    }

    private func sample(_ text: String = "final words") -> CompletedDictation {
        CompletedDictation(createdAt: Date(timeIntervalSince1970: 200), rawText: "raw \(text)", finalText: text,
                           appBundleID: "com.apple.TextEdit", appName: "TextEdit", modelID: "selected-model", durationSeconds: 2.5)
    }

    private func records() throws -> [MemoryRecord] {
        let store = try MemoryStore(directory: directory)
        defer { try? store.close() }
        return try store.listRecent(limit: .max)
    }
}

private struct TestFailure: LocalizedError {
    var errorDescription: String? { "Test failure" }
}

private actor Suspension {
    private var released = false
    nonisolated let entered = XCTestExpectation(description: "Operation started")
    private var hasEntered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        if !hasEntered {
            hasEntered = true
            entered.fulfill()
        }
        if !released { await withCheckedContinuation { waiters.append($0) } }
    }

    func release() {
        released = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

private actor ControlledRepository: HistoryRepository {
    var writes: [CompletedDictation] = []
    var queries: [String] = []
    var deletedBatches: [[UUID]] = []
    private var openFails = false
    private var saveFails = false
    private var deleteFails = false
    private var searchFails = false
    private var openGate: Suspension?
    private var saveGate: Suspension?
    private var searchGate: Suspension?
    private var deleteGate: Suspension?
    private var entries = [record("one"), record("two")]

    func failOpen() { openFails = true }
    func failSave() { saveFails = true }
    func failSearch() { searchFails = true }
    func failDelete(_ value: Bool) { deleteFails = value }
    func setOpenGate(_ gate: Suspension) { openGate = gate }
    func setSaveGate(_ gate: Suspension) { saveGate = gate }
    func setSearchGate(_ gate: Suspension) { searchGate = gate }
    func setDeleteGate(_ gate: Suspension) { deleteGate = gate }
    func resetQueries() { queries = [] }

    func open() async throws {
        await openGate?.enter()
        if openFails { throw TestFailure() }
    }

    func append(_ dictation: CompletedDictation) async throws -> MemoryRecord {
        await saveGate?.enter()
        try Task.checkCancellation()
        if saveFails { throw TestFailure() }
        writes.append(dictation)
        let saved = Self.record(dictation.finalText)
        entries.insert(saved, at: 0)
        return saved
    }

    func records(query: String, limit: Int) async throws -> [MemoryRecord] {
        if searchFails { throw TestFailure() }
        if !query.isEmpty { await searchGate?.enter() }
        queries.append(query)
        return query.isEmpty ? Array(entries.prefix(limit)) : [Self.record(query)]
    }

    func delete(ids: [UUID]) async throws {
        await deleteGate?.enter()
        if deleteFails { throw TestFailure() }
        deletedBatches.append(ids)
        entries.removeAll { ids.contains($0.id) }
    }

    func deleteAll() async throws {
        await deleteGate?.enter()
        if deleteFails { throw TestFailure() }
        entries = []
    }

    private static func record(_ text: String) -> MemoryRecord {
        MemoryRecord(id: UUID(), deviceID: UUID(), kind: .dictation, createdAt: .now, rawText: text, finalText: text,
                     appBundleID: nil, appName: nil, project: nil, modelID: nil, durationSeconds: nil,
                     audioPath: nil, deletedAt: nil)
    }
}
