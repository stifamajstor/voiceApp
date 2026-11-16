import Combine
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
        let history = DictationHistory(repository: repository, notifications: FakeNotifications(), defaults: defaults)
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
        let relaunched = DictationHistory(repository: SQLiteHistoryRepository(directory: directory), notifications: FakeNotifications(), defaults: defaults)
        await relaunched.start().value
        XCTAssertEqual(relaunched.recent.map(\.text), [result.finalText])
    }

    func testDisabledHistoryPersistsPreferenceAndDoesNotWriteOrLoadStoredRecent() async throws {
        let store = try MemoryStore(directory: directory)
        try store.append(rawText: "stored")
        try store.close()
        let repository = SQLiteHistoryRepository(directory: directory)
        let history = DictationHistory(repository: repository, notifications: FakeNotifications(), defaults: defaults)
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
        let relaunched = DictationHistory(repository: repository, notifications: FakeNotifications(), defaults: defaults)
        XCTAssertFalse(relaunched.saveEnabled)
    }

    func testUnavailableStoreStillPastesAndExposesReason() async throws {
        let repository = ControlledRepository()
        await repository.failOpen(TestFailure())
        var logs: [String] = []
        let history = DictationHistory(repository: repository, notifications: FakeNotifications(), defaults: defaults, log: { logs.append($0) })
        await history.start().value
        XCTAssertEqual(history.storeError, "Could not open dictation history. History is not being saved; dictation still works. The cause is in the log.")
        XCTAssertTrue(logs.contains { $0.contains("SELECT * FROM records") })
        var pasted = false
        await history.deliver(sample()) { _ in pasted = true }
        await history.pendingSave?.value
        XCTAssertTrue(pasted)
        XCTAssertEqual(history.recent.count, 1)
        let writes = await repository.writes
        XCTAssertTrue(writes.isEmpty)
    }

    func testSlowOpenNeverDelaysPasteAndAcceptedSaveSurvivesDisabling() async throws {
        let repository = ControlledRepository()
        let gate = Suspension()
        await repository.setOpenGate(gate)
        let history = DictationHistory(repository: repository, notifications: FakeNotifications(), defaults: defaults)
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
        XCTAssertEqual(writes.map(\.finalText), ["final words"])
    }

    func testSlowSaveNeverDelaysPasteOrAnotherDictation() async throws {
        let repository = ControlledRepository()
        let gate = Suspension()
        await repository.setSaveGate(gate)
        let history = DictationHistory(repository: repository, notifications: FakeNotifications(), defaults: defaults)
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

    func testDisablingHistoryKeepsAcceptedSaveWaitingForTheStore() async throws {
        let repository = ControlledRepository()
        let gate = Suspension()
        await repository.setSaveGate(gate)
        let history = DictationHistory(repository: repository, notifications: FakeNotifications(), defaults: defaults)
        await history.start().value
        await history.deliver(sample()) { _ in }
        await fulfillment(of: [gate.entered], timeout: 2)
        history.saveEnabled = false
        await gate.release()
        await history.pendingSave?.value
        let writes = await repository.writes
        XCTAssertEqual(writes.map(\.finalText), ["final words"])
    }

    func testEnablingHistoryDuringPasteDoesNotSaveAPrivateDictation() async throws {
        let repository = ControlledRepository()
        let history = DictationHistory(repository: repository, notifications: FakeNotifications(), defaults: defaults)
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
        let history = DictationHistory(repository: repository, notifications: FakeNotifications(), defaults: defaults, log: { logs.append($0) })
        await history.start().value
        var pasted = false
        await history.deliver(sample()) { _ in pasted = true }
        await history.pendingSave?.value
        XCTAssertTrue(pasted)
        XCTAssertEqual(logs.count, 1)
        XCTAssertEqual(history.saveError, "Could not save this dictation. History is not being saved; dictation still works. The cause is in the log.")
        XCTAssertTrue(logs[0].contains("SELECT * FROM records"))
    }

    func testMenuDisclosureTracksSaveFailureAndRecovery() async {
        let repository = ControlledRepository()
        let history = DictationHistory(repository: repository, notifications: FakeNotifications(), defaults: defaults, log: { _ in })
        await history.start().value
        let savedDisclosure = history.savingDisclosure
        await repository.failSave()
        await history.deliver(sample("failed")) { _ in }
        await history.pendingSave?.value
        XCTAssertEqual(history.savingDisclosure,
                       "Dictation history is not being saved. Dictation still works. The cause is in the log.")
        await repository.failSave(false)
        await history.deliver(sample("saved")) { _ in }
        await history.pendingSave?.value
        XCTAssertNil(history.saveError)
        XCTAssertEqual(history.savingDisclosure, savedDisclosure)
    }

    func testOnlyOpenTimeoutOffersRelaunch() async {
        let repository = ControlledRepository()
        await repository.failOpen(MemoryStore.StoreError.migrationLockTimeout)
        let history = DictationHistory(repository: repository, notifications: FakeNotifications(), defaults: defaults, log: { _ in })
        await history.start().value
        XCTAssertEqual(history.storeError,
                       "Opening dictation history timed out. History is not being saved; dictation still works. The cause is in the log. Relaunch VoiceApp to try opening it again.")
    }

    func testClipboardFallbackStillRetainsSuccessfulTranscription() async throws {
        let repository = ControlledRepository()
        let history = DictationHistory(repository: repository, notifications: FakeNotifications(), defaults: defaults)
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
        let history = DictationHistory(repository: repository, notifications: FakeNotifications(), defaults: defaults)
        await history.start().value
        for index in 0..<5 {
            await history.deliver(sample("entry \(index)")) { _ in }
            await history.pendingSave?.value
        }
        XCTAssertEqual(history.recent.map(\.text), ["entry 4", "entry 3", "entry 2"])
        await history.deliver(sample("queued")) { _ in }
        history.clearRecent()
        await history.pendingSave?.value
        await history.pendingSearch?.value
        await history.refreshRecent()
        XCTAssertTrue(history.recent.isEmpty)
        XCTAssertEqual(try records().count, 6)
        await history.deliver(sample("new")) { _ in }
        await history.pendingSave?.value
        XCTAssertEqual(history.recent.map(\.text), ["new"])
        await history.pendingDeletion?.value
        await history.pendingSearch?.value
        await history.refreshRecent()
        XCTAssertEqual(try records().count, 7)
    }

    func testClearRecentNeverRequestsDeletionAfterQueueDrainsAndQuietInterval() async {
        let repository = ControlledRepository()
        let noDelete = expectation(description: "Clear recent never requests any repository delete")
        noDelete.isInverted = true
        await repository.observeDeletes { noDelete.fulfill() }
        let history = DictationHistory(repository: repository, notifications: FakeNotifications(), defaults: defaults)
        await history.start().value
        let saveGate = Suspension()
        await repository.setSaveGate(saveGate)
        await history.deliver(sample("queued")) { _ in }
        await fulfillment(of: [saveGate.entered], timeout: 2)
        history.clearRecent()
        await saveGate.release()
        await history.pendingSave?.value
        await history.pendingDeletion?.value
        await history.pendingSearch?.value
        await history.refreshRecent()
        XCTAssertTrue(history.recent.isEmpty)
        await history.deliver(sample("new")) { _ in }
        await history.pendingSave?.value
        await history.pendingSearch?.value
        XCTAssertEqual(history.recent.map(\.text), ["new"])
        // Observe absence after draining, including untracked delayed background deletes
        // (a delete delayed by 1.5 s must still be caught).
        await fulfillment(of: [noDelete], timeout: 2)
        let deleteRequests = await repository.deleteRequests
        XCTAssertTrue(deleteRequests.isEmpty)
        let writes = await repository.writes
        XCTAssertEqual(writes.map(\.finalText), ["queued", "new"])
    }

    func testSearchUsesStorePrefixAndNewestFirstIncludingTimestampTies() async throws {
        let store = try MemoryStore(directory: directory)
        let older = try store.append(createdAt: Date(timeIntervalSince1970: 100), rawText: "hello world")
        _ = try store.append(kind: .note, rawText: "hello world")
        let newer = try store.append(createdAt: Date(timeIntervalSince1970: 200), rawText: "hello world again")
        let tie = try store.append(createdAt: newer.createdAt, rawText: "hello worldly")
        _ = try store.append(rawText: "hellos world")
        try store.close()
        let history = DictationHistory(repository: SQLiteHistoryRepository(directory: directory), notifications: FakeNotifications(), defaults: defaults,
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
        let history = DictationHistory(repository: repository, notifications: FakeNotifications(), defaults: defaults, debounce: { _ in await debounce.enter() })
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
        let history = DictationHistory(repository: repository, notifications: FakeNotifications(), defaults: defaults, debounce: { _ in })
        await history.start().value
        history.query = "old"
        await fulfillment(of: [gate.entered], timeout: 2)
        let older = history.pendingSearch
        await repository.setSearchGate(nil)
        history.query = "new"
        await history.pendingSearch?.value
        XCTAssertEqual(history.results.map(\.finalText), ["new"])
        await gate.release()
        await older?.value
        XCTAssertEqual(history.results.map(\.finalText), ["new"])
        XCTAssertFalse(history.isSearching)
    }

    func testSelectedDeleteUsesOneBatchAndKeepsBusyUntilCompletion() async throws {
        let repository = ControlledRepository()
        let history = DictationHistory(repository: repository, notifications: FakeNotifications(), defaults: defaults)
        await history.start().value
        await history.refresh()
        let selected = Set(history.results.map(\.id))
        history.selection = selected
        let gate = Suspension()
        await repository.setDeleteGate(gate)
        history.requestDeleteSelected()
        let deletion = Task { await history.deleteSelected()?.value }
        await fulfillment(of: [gate.entered], timeout: 2)
        XCTAssertTrue(history.isDeleting)
        XCTAssertEqual(history.results.count, 2)
        history.requestDeleteSelected()
        await history.deleteSelected()?.value
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
        var logs: [String] = []
        let history = DictationHistory(repository: repository, notifications: FakeNotifications(), defaults: defaults, log: { logs.append($0) })
        await history.start().value
        await history.refresh()
        history.selection = [try XCTUnwrap(history.results.first).id]
        let before = history.results
        let selected = history.selection
        await repository.failDelete(true)
        history.requestDeleteSelected()
        await history.deleteSelected()?.value
        XCTAssertEqual(history.results, before)
        XCTAssertEqual(history.selection, selected)
        XCTAssertTrue(logs.contains { $0.contains("SELECT * FROM records") })
        XCTAssertEqual(history.deleteError, "Could not delete dictation history. Try again. The cause is in the log.")
        XCTAssertFalse(history.isDeleting)
        await repository.failDelete(false)
        history.requestDeleteSelected()
        await history.deleteSelected()?.value
        XCTAssertEqual(history.results.count, 1)
        XCTAssertNil(history.deleteError)
    }

    func testDeleteAllRequiresConfirmationAndDeletesBeyondVisibleSearchResults() async throws {
        let store = try MemoryStore(directory: directory)
        for index in 0..<105 { try store.append(rawText: "entry \(index)") }
        let note = try store.append(kind: .note, rawText: "keep note")
        try store.close()
        let history = DictationHistory(repository: SQLiteHistoryRepository(directory: directory), notifications: FakeNotifications(), defaults: defaults,
                                       debounce: { _ in })
        await history.start().value
        await history.refresh()
        XCTAssertEqual(history.results.count, 100)
        XCTAssertTrue(history.hasMore)
        await history.loadMore()
        XCTAssertEqual(history.results.count, 105)
        XCTAssertEqual(history.deleteAllCount, 105)
        history.requestDeleteAll()
        XCTAssertTrue(history.isDeleteConfirmationPresented, "Delete all must show its alert")
        XCTAssertEqual(history.deleteConfirmationTitle, "Delete 105 dictations?")
        history.cancelDeleteAll()
        XCTAssertFalse(history.isDeleteConfirmationPresented)
        history.query = "entry 1"
        await history.pendingSearch?.value
        await history.confirmDeleteAll()?.value
        XCTAssertEqual(try records().count, 106)
        history.requestDeleteAll()
        history.cancelDeleteAll()
        await history.confirmDeleteAll()?.value
        XCTAssertEqual(try records().count, 106)
        history.requestDeleteAll()
        await history.confirmDeleteAll()?.value
        XCTAssertEqual(try records(), [note])
        XCTAssertEqual(history.deleteAllCount, 0)
        XCTAssertTrue(history.results.isEmpty)
        XCTAssertTrue(history.recent.isEmpty)
        XCTAssertFalse(history.isDeleting)
    }

    func testSearchCompletionDoesNotHideDeleteFailure() async throws {
        let repository = ControlledRepository()
        let history = DictationHistory(repository: repository, notifications: FakeNotifications(), defaults: defaults, debounce: { _ in })
        await history.start().value
        await history.refresh()
        history.selection = [try XCTUnwrap(history.results.first).id]
        await repository.failDelete(true)
        let gate = Suspension()
        await repository.setSearchGate(gate)
        history.requestDeleteSelected()
        history.query = "new search"
        await fulfillment(of: [gate.entered], timeout: 2)
        await history.deleteSelected()?.value
        XCTAssertEqual(history.deleteError, "Could not delete dictation history. Try again. The cause is in the log.")
        await gate.release()
        await history.pendingSearch?.value
        XCTAssertEqual(history.deleteError, "Could not delete dictation history. Try again. The cause is in the log.")
    }

    func testLockedStoreSaveDoesNotDelayPasteOrMainActor() async throws {
        let repository = SQLiteHistoryRepository(directory: directory)
        let history = DictationHistory(repository: repository, notifications: FakeNotifications(), defaults: defaults)
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
        var logs: [String] = []
        let history = DictationHistory(repository: repository, notifications: FakeNotifications(), defaults: defaults, debounce: { _ in }, log: { logs.append($0) })
        await history.start().value
        await repository.failSearch()
        history.query = "failure"
        await history.pendingSearch?.value
        XCTAssertFalse(history.isSearching)
        XCTAssertTrue(history.results.isEmpty)
        XCTAssertEqual(history.searchError, "Could not search dictation history. Try again. The cause is in the log.")
        XCTAssertTrue(logs.contains { $0.contains("SELECT * FROM records") })
    }

    func testDeleteAllOrdersPendingSaveDeleteAndLaterSave() async throws {
        try await assertDeleteOrdering(all: true)
    }

    func testSelectedDeleteOrdersPendingSaveDeleteAndLaterSave() async throws {
        try await assertDeleteOrdering(all: false)
    }

    private func assertDeleteOrdering(all: Bool) async throws {
        let repository = ControlledRepository()
        let history = DictationHistory(repository: repository, notifications: FakeNotifications(), defaults: defaults)
        await history.start().value
        await history.refresh()
        history.selection = Set(history.results.map(\.id))
        let saveGate = Suspension()
        let deleteGate = Suspension()
        await repository.setSaveGate(saveGate)
        await repository.setDeleteGate(deleteGate)
        await history.deliver(sample("before")) { _ in }
        await fulfillment(of: [saveGate.entered], timeout: 2)
        let deleting = expectation(description: "Delete accepted")
        let observation = history.$isDeleting.filter { $0 }.prefix(1).sink { _ in deleting.fulfill() }
        if all { history.requestDeleteAll() }
        let deletion = Task {
            if all { await history.confirmDeleteAll()?.value }
            else {
                history.requestDeleteSelected()
                await history.deleteSelected()?.value
            }
        }
        await fulfillment(of: [deleting], timeout: 2)
        await history.deliver(sample("after")) { _ in }
        let eventsWhileBlocked = await repository.events
        XCTAssertTrue(eventsWhileBlocked.isEmpty)
        await saveGate.release()
        await fulfillment(of: [deleteGate.entered], timeout: 2)
        let eventsBeforeDelete = await repository.events
        XCTAssertEqual(eventsBeforeDelete, ["save:before", "delete"])
        await deleteGate.release()
        await deletion.value
        await history.pendingSave?.value
        let events = await repository.events
        XCTAssertEqual(events, ["save:before", "delete", "save:after"])
        let remaining = try await repository.records(query: "", limit: 100)
        XCTAssertTrue(remaining.contains { $0.finalText == "after" })
        XCTAssertTrue(history.recent.contains { $0.text == "after" })
        if all {
            XCTAssertEqual(remaining.map(\.finalText), ["after"])
            XCTAssertEqual(history.deleteAllCount, 1)
        }
        withExtendedLifetime(observation) {}
    }

    func testDeletingPersistedDictationRemovesItFromMenu() async throws {
        let history = DictationHistory(repository: SQLiteHistoryRepository(directory: directory), notifications: FakeNotifications(), defaults: defaults)
        await history.start().value
        await history.deliver(sample("delete me")) { _ in }
        await history.pendingSave?.value
        await history.refresh()
        let record = try XCTUnwrap(history.results.first)
        XCTAssertEqual(history.recent.map(\.id), [record.id])
        history.selection = [record.id]
        history.requestDeleteSelected()
        await history.deleteSelected()?.value
        XCTAssertTrue(history.recent.isEmpty)
        XCTAssertTrue(try records().isEmpty)
    }

    func testDisablingDuringPasteKeepsAcceptedDictationAndRejectsLaterOnes() async throws {
        let repository = ControlledRepository()
        let history = DictationHistory(repository: repository, notifications: FakeNotifications(), defaults: defaults)
        await history.start().value
        await history.deliver(sample("accepted")) { _ in history.saveEnabled = false }
        await history.deliver(sample("private")) { _ in }
        await history.pendingSave?.value
        let writes = await repository.writes
        XCTAssertEqual(writes.map(\.finalText), ["accepted"])
    }

    func testTerminationWithEmptyQueueIsImmediate() async {
        let history = DictationHistory(repository: ControlledRepository(), notifications: FakeNotifications(), defaults: defaults)
        let termination = HistoryTermination(history: history, showHistory: { XCTFail("No failure") },
                                             waitForDeadline: { _ in XCTFail("No deadline needed") })
        XCTAssertTrue(termination.requestTermination { _ in XCTFail("Immediate quit needs no reply") })
    }

    func testMenuQuitIgnoresSecondRequestAndWorksAfterCancellation() async {
        let repository = ControlledRepository()
        let deleteGate = Suspension()
        await repository.setDeleteGate(deleteGate)
        await repository.failDelete(true)
        let history = DictationHistory(repository: repository, notifications: FakeNotifications(), defaults: defaults, log: { _ in })
        await history.start().value
        history.requestDeleteAll()
        let deletion = history.confirmDeleteAll()
        await fulfillment(of: [deleteGate.entered], timeout: 2)
        let termination = HistoryTermination(history: history)
        var pendingStates: [Bool] = []
        let observation = termination.$isQuitPending.sink { pendingStates.append($0) }
        var terminateCalls = 0
        var replies: [Bool] = []
        let replied = expectation(description: "Delete failure cancels menu quit")
        let terminate = {
            terminateCalls += 1
            _ = termination.requestTermination {
                replies.append($0)
                replied.fulfill()
            }
        }
        termination.requestQuit(terminate: terminate)
        XCTAssertTrue(termination.isQuitPending)
        termination.requestQuit(terminate: terminate)
        XCTAssertEqual(terminateCalls, 1)
        await deleteGate.release()
        await deletion?.value
        await fulfillment(of: [replied], timeout: 2)
        XCTAssertEqual(replies, [false])
        XCTAssertFalse(termination.isQuitPending)
        XCTAssertEqual(pendingStates, [false, true, false])
        termination.requestQuit(terminate: terminate)
        XCTAssertEqual(terminateCalls, 2)
        XCTAssertEqual(replies, [false])
        withExtendedLifetime(observation) {}
    }

    func testOldDeleteFailureDoesNotCancelLaterQuitWithSaveInFlight() async {
        let repository = ControlledRepository()
        await repository.failDelete(true)
        let history = DictationHistory(repository: repository, notifications: FakeNotifications(), defaults: defaults, log: { _ in })
        await history.start().value
        history.requestDeleteAll()
        await history.confirmDeleteAll()?.value
        XCTAssertNotNil(history.deleteError)
        let saveGate = Suspension()
        await repository.setSaveGate(saveGate)
        await history.deliver(sample()) { _ in }
        await fulfillment(of: [saveGate.entered], timeout: 2)
        let termination = HistoryTermination(history: history, showHistory: { XCTFail("Old failure must not open History") })
        var replies: [Bool] = []
        let replied = expectation(description: "Quit despite old delete failure")
        XCTAssertFalse(termination.requestTermination {
            replies.append($0)
            replied.fulfill()
        })
        await saveGate.release()
        await history.pendingSave?.value
        await fulfillment(of: [replied], timeout: 2)
        XCTAssertEqual(replies, [true])
    }

    func testTerminationWaitsForEntireSaveTailAndIgnoresCancelledDeadline() async throws {
        let repository = ControlledRepository()
        let history = DictationHistory(repository: repository, notifications: FakeNotifications(), defaults: defaults)
        await history.start().value
        let recentGate = Suspension()
        let deadline = Suspension()
        await repository.setRecentGate(recentGate)
        await history.deliver(sample()) { _ in }
        await fulfillment(of: [recentGate.entered], timeout: 2)
        let termination = HistoryTermination(history: history, waitForDeadline: { _ in
            await deadline.enter()
        })
        var replies: [Bool] = []
        let replied = expectation(description: "Quit after save refresh")
        XCTAssertFalse(termination.requestTermination {
            replies.append($0)
            replied.fulfill()
        })
        await fulfillment(of: [deadline.entered], timeout: 2)
        let deadlineTask = termination.deadline
        XCTAssertTrue(replies.isEmpty)
        await recentGate.release()
        await history.pendingSave?.value
        await fulfillment(of: [replied], timeout: 2)
        XCTAssertEqual(replies, [true])
        await deadline.release()
        await deadlineTask?.value
        XCTAssertEqual(replies, [true])
    }

    func testTerminationWaitsForSavesIncludingDeliveriesWhileQuitIsPending() async throws {
        let repository = ControlledRepository()
        let gate = Suspension()
        await repository.setSaveGate(gate)
        let history = DictationHistory(repository: repository, notifications: FakeNotifications(), defaults: defaults)
        await history.start().value
        await history.deliver(sample("first")) { _ in }
        await fulfillment(of: [gate.entered], timeout: 2)
        let termination = HistoryTermination(history: history)
        var replies: [Bool] = []
        let replied = expectation(description: "Quit after all saves")
        XCTAssertFalse(termination.requestTermination {
            replies.append($0)
            replied.fulfill()
        })
        XCTAssertFalse(termination.requestTermination { _ in XCTFail("Duplicate reply") })
        var pasted: [String] = []
        await history.deliver(sample("second")) { pasted.append($0) }
        await history.deliver(sample("third")) { pasted.append($0) }
        XCTAssertEqual(pasted, ["second", "third"])
        XCTAssertTrue(replies.isEmpty)
        await gate.release()
        await history.pendingSave?.value
        await fulfillment(of: [replied], timeout: 2)
        XCTAssertEqual(replies, [true])
        let writes = await repository.writes
        XCTAssertEqual(writes.map(\.finalText), ["first", "second", "third"])
        XCTAssertFalse(termination.requestTermination { _ in XCTFail("Successful quit already replied") })
    }

    func testTerminationWaitsForSavesQueuedAfterDelete() async throws {
        let repository = ControlledRepository()
        let deletionGate = Suspension()
        let saveGate = Suspension()
        await repository.setDeleteGate(deletionGate)
        await repository.setSaveGate(saveGate)
        let history = DictationHistory(repository: repository, notifications: FakeNotifications(), defaults: defaults)
        await history.start().value
        history.requestDeleteAll()
        let deletion = history.confirmDeleteAll()
        await fulfillment(of: [deletionGate.entered], timeout: 2)
        await history.deliver(sample("after")) { _ in }
        let termination = HistoryTermination(history: history)
        let replied = expectation(description: "Quit after delete and saves")
        var replies: [Bool] = []
        XCTAssertFalse(termination.requestTermination {
            replies.append($0)
            replied.fulfill()
        })
        await deletionGate.release()
        await deletion?.value
        await fulfillment(of: [saveGate.entered], timeout: 2)
        XCTAssertTrue(replies.isEmpty)
        await saveGate.release()
        await history.pendingSave?.value
        await fulfillment(of: [replied], timeout: 2)
        XCTAssertEqual(replies, [true])
        let events = await repository.events
        XCTAssertEqual(events, ["delete", "save:after"])
    }

    func testTerminationDeadlineRepliesOnceWithoutCancellingQueuedSaves() async throws {
        let repository = ControlledRepository()
        let saveGate = Suspension()
        let deadline = Suspension()
        await repository.setSaveGate(saveGate)
        let history = DictationHistory(repository: repository, notifications: FakeNotifications(), defaults: defaults)
        await history.start().value
        await history.deliver(sample()) { _ in }
        await fulfillment(of: [saveGate.entered], timeout: 2)
        let termination = HistoryTermination(history: history, waitForDeadline: { duration in
            XCTAssertEqual(duration, .seconds(30))
            await deadline.enter()
        })
        let replied = expectation(description: "Quit at deadline")
        var replies: [Bool] = []
        XCTAssertFalse(termination.requestTermination {
            replies.append($0)
            replied.fulfill()
        })
        await fulfillment(of: [deadline.entered], timeout: 2)
        XCTAssertTrue(replies.isEmpty)
        let queueWaiter = termination.waiting
        await deadline.release()
        await fulfillment(of: [replied], timeout: 2)
        XCTAssertEqual(replies, [true])
        let before = await repository.writes
        XCTAssertTrue(before.isEmpty)
        await saveGate.release()
        await history.pendingSave?.value
        await queueWaiter?.value
        let after = await repository.writes
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(replies, [true])
        var terminateCalls = 0
        termination.requestQuit { terminateCalls += 1 }
        XCTAssertEqual(terminateCalls, 0)
    }

    func testTerminationDeadlineStillCancelsQuitAfterFailedDelete() async throws {
        let repository = ControlledRepository()
        let saveGate = Suspension()
        let deadline = Suspension()
        await repository.failDelete(true)
        await repository.setSaveGate(saveGate)
        let history = DictationHistory(repository: repository, notifications: FakeNotifications(), defaults: defaults)
        await history.start().value
        history.requestDeleteAll()
        let deletion = history.confirmDeleteAll()
        await history.deliver(sample()) { _ in }
        let termination = HistoryTermination(history: history, waitForDeadline: { _ in await deadline.enter() })
        let replied = expectation(description: "Cancel quit at deadline")
        var replies: [Bool] = []
        XCTAssertFalse(termination.requestTermination {
            replies.append($0)
            replied.fulfill()
        })
        await deletion?.value
        await fulfillment(of: [saveGate.entered, deadline.entered], timeout: 2)
        let queueWaiter = termination.waiting
        await deadline.release()
        await fulfillment(of: [replied], timeout: 2)
        XCTAssertEqual(replies, [false])
        await saveGate.release()
        await history.pendingSave?.value
        await queueWaiter?.value
        XCTAssertEqual(replies, [false])
    }

    func testTerminationWaitsForDeleteAndRepliesOnce() async throws {
        try await assertTerminationWaits(deleteFails: false)
    }

    func testTerminationCancelsQuitWhenDeleteFails() async throws {
        try await assertTerminationWaits(deleteFails: true)
    }

    private func assertTerminationWaits(deleteFails: Bool) async throws {
        let repository = ControlledRepository()
        let history = DictationHistory(repository: repository, notifications: FakeNotifications(), defaults: defaults)
        await history.start().value
        var historyShown = 0
        var replies: [Bool] = []
        let termination = HistoryTermination(history: history, showHistory: {
            XCTAssertEqual(replies, [false])
            XCTAssertNotNil(history.deleteError)
            historyShown += 1
        })
        XCTAssertTrue(termination.requestTermination { _ in XCTFail("No asynchronous reply needed") })
        let gate = Suspension()
        await repository.setDeleteGate(gate)
        await repository.failDelete(deleteFails)
        history.requestDeleteAll()
        let deletion = Task { await history.confirmDeleteAll()?.value }
        await fulfillment(of: [gate.entered], timeout: 2)
        let replied = expectation(description: "Termination replied after deletion")
        XCTAssertFalse(termination.requestTermination {
            replies.append($0)
            replied.fulfill()
        })
        XCTAssertFalse(termination.requestTermination { _ in XCTFail("Duplicate quit request") })
        XCTAssertTrue(replies.isEmpty)
        await gate.release()
        await deletion.value
        await fulfillment(of: [replied], timeout: 2)
        XCTAssertEqual(replies, [!deleteFails])
        XCTAssertEqual(historyShown, deleteFails ? 1 : 0)
        XCTAssertFalse(history.isDeleting)
    }

    func testSelectedDeletionRequiresConfirmationAndCancelKeepsRecords() async throws {
        let repository = ControlledRepository()
        let history = DictationHistory(repository: repository, notifications: FakeNotifications(), defaults: defaults)
        await history.start().value
        await history.refresh()
        history.selection = [try XCTUnwrap(history.results.first).id]
        await history.deleteSelected()?.value
        let batches = await repository.deletedBatches
        XCTAssertTrue(batches.isEmpty)
        XCTAssertEqual(history.results.count, 2)
        history.requestDeleteSelected()
        XCTAssertTrue(history.isDeleteConfirmationPresented)
        XCTAssertEqual(history.selectedDeleteCount, 1)
        XCTAssertEqual(history.deleteConfirmationTitle, "Delete 1 dictation?")
        history.cancelDeleteSelected()
        XCTAssertFalse(history.needsDeleteSelectedConfirmation)
        await history.deleteSelected()?.value
        XCTAssertEqual(history.results.count, 2)
        history.requestDeleteSelected()
        XCTAssertTrue(history.isDeleteConfirmationPresented)
        history.selection = []
        // SwiftUI may dismiss the alert binding before invoking its destructive action.
        history.isDeleteConfirmationPresented = false
        await history.deleteSelected()?.value
        XCTAssertEqual(history.results.count, 1)
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
    var errorDescription: String? { "Test failure: SELECT * FROM records WHERE deletedAt IS NULL" }
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
    func appendNote(_ note: CompletedDictation) async throws { throw CocoaError(.featureUnsupported) }
    func notes(query: String, remindersOnly: Bool, limit: Int) async throws -> [VoiceNote] { [] }
    func editNote(id: UUID, text: String) async throws { throw CocoaError(.featureUnsupported) }
    func setNoteDone(id: UUID, isDone: Bool) async throws { throw CocoaError(.featureUnsupported) }
    func markNoteReminderNotified(id: UUID, at date: Date) async throws { throw CocoaError(.featureUnsupported) }
    func setNoteReminder(id: UUID, date: Date?) async throws { throw CocoaError(.featureUnsupported) }

    var events: [String] = []
    var writes: [CompletedDictation] = []
    var queries: [String] = []
    var deletedBatches: [[UUID]] = []
    var deleteRequests: [[UUID]?] = []
    private var onDelete: @Sendable () -> Void = {}
    private var openFailure: Error?
    private var saveFails = false
    private var deleteFails = false
    private var searchFails = false
    private var openGate: Suspension?
    private var saveGate: Suspension?
    private var recentGate: Suspension?
    private var searchGate: Suspension?
    private var deleteGate: Suspension?
    private var entries = [record("one"), record("two")]

    func failOpen(_ error: Error) { openFailure = error }
    func failSave(_ value: Bool = true) { saveFails = value }
    func failSearch() { searchFails = true }
    func failDelete(_ value: Bool) { deleteFails = value }
    func setOpenGate(_ gate: Suspension) { openGate = gate }
    func setSaveGate(_ gate: Suspension) { saveGate = gate }
    func setRecentGate(_ gate: Suspension) { recentGate = gate }
    func setSearchGate(_ gate: Suspension?) { searchGate = gate }
    func setDeleteGate(_ gate: Suspension) { deleteGate = gate }
    func resetQueries() { queries = [] }
    func observeDeletes(_ observation: @escaping @Sendable () -> Void) { onDelete = observation }

    func open() async throws {
        await openGate?.enter()
        if let openFailure { throw openFailure }
    }

    func append(_ dictation: CompletedDictation) async throws -> MemoryRecord {
        await saveGate?.enter()
        try Task.checkCancellation()
        if saveFails { throw TestFailure() }
        events.append("save:\(dictation.finalText)")
        writes.append(dictation)
        let saved = Self.record(dictation.finalText, id: dictation.id)
        entries.insert(saved, at: 0)
        return saved
    }

    func records(query: String, limit: Int) async throws -> [MemoryRecord] {
        if searchFails { throw TestFailure() }
        if query.isEmpty { await recentGate?.enter() }
        else { await searchGate?.enter() }
        queries.append(query)
        return query.isEmpty ? Array(entries.prefix(limit)) : [Self.record(query)]
    }

    func delete(ids: [UUID]) async throws {
        deleteRequests.append(ids)
        onDelete()
        events.append("delete")
        await deleteGate?.enter()
        if deleteFails { throw TestFailure() }
        deletedBatches.append(ids)
        entries.removeAll { ids.contains($0.id) }
    }

    func deleteAll() async throws {
        deleteRequests.append(nil)
        onDelete()
        events.append("delete")
        await deleteGate?.enter()
        if deleteFails { throw TestFailure() }
        entries = []
    }

    private static func record(_ text: String, id: UUID = UUID()) -> MemoryRecord {
        MemoryRecord(id: id, deviceID: UUID(), kind: .dictation, createdAt: .now, rawText: text, finalText: text,
                     appBundleID: nil, appName: nil, project: nil, modelID: nil, durationSeconds: nil,
                     audioPath: nil, deletedAt: nil)
    }
}
