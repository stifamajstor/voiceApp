import Foundation
import GRDB
@testable import VoiceAppCore
import XCTest

@MainActor
final class UserDictionaryTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var defaultsName: String!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defaultsName = "UserDictionaryTests.\(UUID())"
        defaults = UserDefaults(suiteName: defaultsName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: defaultsName)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    func testDictationPastedTextUsesDictionaryAndHistoryKeepsRawAndFinalText() async throws {
        let repository = SQLiteHistoryRepository(directory: directory)
        let history = DictationHistory(repository: repository, notifications: FakeNotifications(), defaults: defaults)
        let dictionary = UserDictionary(repository: repository)
        let delivery = DictationDelivery(history: history, dictionary: dictionary)
        await history.start().value
        await dictionary.start().value

        try await dictionary.addTerm(text: " Mac ", aliases: UserDictionary.parseAliases(" MEC , , Meg\n"))

        var pasted: [String] = []
        let deliveredEmpty = try await delivery.deliver(
            rawText: " [BLANK_AUDIO] ",
            appBundleID: "com.apple.TextEdit",
            appName: "TextEdit",
            modelID: "parakeet-tdt-0.6b-v3",
            durationSeconds: 0.5
        ) { pasted.append($0) }
        XCTAssertFalse(deliveredEmpty)
        XCTAssertTrue(pasted.isEmpty)

        let delivered = try await delivery.deliver(
            rawText: "  this MEC is fast  ",
            appBundleID: "com.apple.TextEdit",
            appName: "TextEdit",
            modelID: "parakeet-tdt-0.6b-v3",
            durationSeconds: 1.5
        ) { pasted.append($0) }
        XCTAssertTrue(delivered)
        XCTAssertEqual(pasted, ["this Mac is fast"])
        await history.pendingSave?.value

        let store = try MemoryStore(directory: directory)
        defer { try? store.close() }
        let saved = try XCTUnwrap(store.listRecent(kind: .dictation, limit: 1).first)
        XCTAssertEqual(saved.rawText, "  this MEC is fast  ")
        XCTAssertEqual(saved.finalText, "this Mac is fast")
        XCTAssertEqual(try store.search("MEC").map(\.id), [saved.id])
        XCTAssertEqual(try store.search("Mac").map(\.id), [saved.id])
    }

    func testBothNoteShortcutsUseDictionaryWithoutPastingAndKeepRawTextAfterReopen() async throws {
        let repository = SQLiteHistoryRepository(directory: directory)
        let history = DictationHistory(repository: repository, notifications: FakeNotifications(), defaults: defaults)
        let dictionary = UserDictionary(repository: repository)
        let delivery = DictationDelivery(history: history, dictionary: dictionary)
        history.saveEnabled = false
        await dictionary.start().value
        try await dictionary.addTerm(text: "Mac", aliases: ["MEC"])

        for trigger in [CaptureTrigger.notePushToTalk, .noteToggle] {
            let empty = try await delivery.deliver(
                rawText: " [BLANK_AUDIO] ", appBundleID: nil, appName: nil,
                modelID: "test-model", durationSeconds: 1, destination: trigger.destination
            ) { _ in XCTFail("A note must never paste") }
            XCTAssertFalse(empty)
            let saved = try await delivery.deliver(
                rawText: "  this MEC is fast  ", appBundleID: "com.apple.TextEdit", appName: "TextEdit",
                modelID: "test-model", durationSeconds: 2, destination: trigger.destination
            ) { _ in XCTFail("A note must never paste") }
            XCTAssertTrue(saved)
        }
        await history.pendingSave?.value
        XCTAssertNil(history.noteError)
        XCTAssertTrue(history.recent.isEmpty)

        let reopened = try MemoryStore(directory: directory)
        defer { try? reopened.close() }
        let notes = try reopened.notes()
        XCTAssertEqual(notes.count, 2)
        for note in notes {
            XCTAssertEqual(note.record.rawText, "  this MEC is fast  ")
            XCTAssertEqual(note.record.finalText, "this Mac is fast")
            XCTAssertEqual(note.text, "this Mac is fast")
            XCTAssertEqual(note.record.appBundleID, "com.apple.TextEdit")
            XCTAssertEqual(note.record.appName, "TextEdit")
        }
        XCTAssertEqual(try reopened.notes(query: "Mac").count, 2)
        XCTAssertEqual(try reopened.count(kind: .dictation), 0)
    }

    func testEditsAndDeletesTakeEffectOnNextDictationWithoutReadingStore() async throws {
        let seedStore = try MemoryStore(directory: directory)
        let initial = try seedStore.addTerm(text: "Mac", aliases: ["MEC", "Meg"])
        try seedStore.close()

        let repository = SpyDictionaryRepository(backing: SQLiteHistoryRepository(directory: directory))
        let history = DictationHistory(repository: FailingHistoryRepository(), notifications: FakeNotifications(), defaults: defaults, log: { _ in })
        let dictionary = UserDictionary(repository: repository)
        let delivery = DictationDelivery(history: history, dictionary: dictionary)
        await dictionary.start().value

        let initialReads = await repository.listCount
        XCTAssertEqual(initialReads, 1)

        await repository.failAllReads(true)
        var pasted: [String] = []
        _ = try await delivery.deliver(
            rawText: "this MEC is fast",
            appBundleID: nil,
            appName: nil,
            modelID: "parakeet-tdt-0.6b-v3",
            durationSeconds: 1.0
        ) { pasted.append($0) }
        _ = try await delivery.deliver(
            rawText: "tell Meg hello",
            appBundleID: nil,
            appName: nil,
            modelID: "parakeet-tdt-0.6b-v3",
            durationSeconds: 1.0
        ) { pasted.append($0) }
        XCTAssertEqual(pasted, ["this Mac is fast", "tell Mac hello"])
        let readsAfterCorrection = await repository.listCount
        XCTAssertEqual(readsAfterCorrection, 1)

        await repository.failAllReads(false)
        let edited = try await dictionary.updateTerm(
            id: initial.id,
            text: " MacBook ",
            aliases: UserDictionary.parseAliases("MEC, , Meg")
        )
        XCTAssertEqual(edited.text, "MacBook")
        XCTAssertEqual(edited.aliases, ["MEC", "Meg"])

        await repository.failAllReads(true)
        var afterEdit: String?
        _ = try await delivery.deliver(
            rawText: "this MEC is fast",
            appBundleID: nil,
            appName: nil,
            modelID: "parakeet-tdt-0.6b-v3",
            durationSeconds: 1.0
        ) { afterEdit = $0 }
        XCTAssertEqual(afterEdit, "this MacBook is fast")

        try await dictionary.deleteTerm(id: initial.id)
        var afterDelete: String?
        _ = try await delivery.deliver(
            rawText: "this MEC is fast",
            appBundleID: nil,
            appName: nil,
            modelID: "parakeet-tdt-0.6b-v3",
            durationSeconds: 1.0
        ) { afterDelete = $0 }
        XCTAssertEqual(afterDelete, "this MEC is fast")
        XCTAssertTrue(dictionary.terms.isEmpty)
        let finalReads = await repository.listCount
        XCTAssertEqual(finalReads, 1)
    }

    func testStoreFailureStillPastesRawTextAndLogsReason() async throws {
        let repository = SpyDictionaryRepository(backing: SQLiteHistoryRepository(directory: directory))
        await repository.failOpen(DictionaryLoadFailure())
        var logs: [String] = []
        let dictionary = UserDictionary(repository: repository, log: { logs.append($0) })
        let history = DictationHistory(repository: FailingHistoryRepository(), notifications: FakeNotifications(), defaults: defaults, log: { _ in })
        let delivery = DictationDelivery(history: history, dictionary: dictionary)

        await dictionary.start().value
        XCTAssertNotNil(dictionary.storeError)
        XCTAssertEqual(logs.count, 1)
        XCTAssertTrue(logs[0].contains("Disk unreadable"))

        var pasted: String?
        let delivered = try await delivery.deliver(
            rawText: "this MEC is fast",
            appBundleID: nil,
            appName: nil,
            modelID: "parakeet-tdt-0.6b-v3",
            durationSeconds: 1.0
        ) { pasted = $0 }
        XCTAssertTrue(delivered)
        XCTAssertEqual(pasted, "this MEC is fast")
    }

    func testSlowDictionaryAndHistoryStoresNeverBlockPaste() async throws {
        let seedStore = try MemoryStore(directory: directory)
        _ = try seedStore.addTerm(text: "Mac", aliases: ["MEC"])
        try seedStore.close()

        let dictionaryRepo = SpyDictionaryRepository(backing: SQLiteHistoryRepository(directory: directory))
        let historyRepo = GatedHistoryRepository()
        let dictionaryGate = DictionaryGate()
        let historyGate = DictionaryGate()
        await dictionaryRepo.setOpenGate(dictionaryGate)
        await historyRepo.setOpenGate(historyGate)
        addTeardownBlock {
            await dictionaryGate.release()
            await historyGate.release()
        }

        let dictionary = UserDictionary(repository: dictionaryRepo)
        let history = DictationHistory(repository: historyRepo, notifications: FakeNotifications(), defaults: defaults)
        let delivery = DictationDelivery(history: history, dictionary: dictionary)

        let historyLoading = history.start()
        let dictionaryLoading = dictionary.start()
        await fulfillment(of: [dictionaryGate.entered, historyGate.entered], timeout: 2)
        XCTAssertTrue(dictionary.isLoading)

        var pastedWhileLoading: String?
        let pasteDuringLoad = expectation(description: "Paste completes while stores are opening")
        let firstDelivery = Task {
            _ = try await delivery.deliver(
                rawText: "this MEC is fast",
                appBundleID: nil,
                appName: nil,
                modelID: "parakeet-tdt-0.6b-v3",
                durationSeconds: 1.0
            ) { pastedWhileLoading = $0 }
            pasteDuringLoad.fulfill()
        }
        await fulfillment(of: [pasteDuringLoad], timeout: 1.0)
        XCTAssertEqual(pastedWhileLoading, "this MEC is fast")

        await dictionaryGate.release()
        _ = try await firstDelivery.value
        await dictionaryLoading.value
        XCTAssertFalse(dictionary.isLoading)

        var pastedWhileHistoryBlocked: String?
        let pasteDuringHistory = expectation(description: "Paste completes while history store is blocked")
        let secondDelivery = Task {
            _ = try await delivery.deliver(
                rawText: "this MEC is fast",
                appBundleID: nil,
                appName: nil,
                modelID: "parakeet-tdt-0.6b-v3",
                durationSeconds: 1.0
            ) { pastedWhileHistoryBlocked = $0 }
            pasteDuringHistory.fulfill()
        }
        await fulfillment(of: [pasteDuringHistory], timeout: 1.0)
        XCTAssertEqual(pastedWhileHistoryBlocked, "this Mac is fast")

        await historyGate.release()
        _ = try await secondDelivery.value
        await historyLoading.value
        await history.pendingSave?.value
        let saved = await historyRepo.saved
        XCTAssertEqual(saved.map(\.finalText), ["this MEC is fast", "this Mac is fast"])
    }

    func testValidationErrorsProducePlainEnglishMessages() async throws {
        let repository = SQLiteHistoryRepository(directory: directory)
        let dictionary = UserDictionary(repository: repository)
        await dictionary.start().value

        let apple = try await dictionary.addTerm(text: "Apple", aliases: ["Apel"])

        do {
            _ = try await dictionary.addTerm(text: "   ", aliases: [])
            XCTFail("Expected blank text error")
        } catch {
            XCTAssertEqual(dictionary.errorMessage(for: error), "Term text cannot be blank.")
        }

        do {
            _ = try await dictionary.addTerm(text: "apple", aliases: [])
            XCTFail("Expected conflict error")
        } catch {
            XCTAssertEqual(dictionary.errorMessage(for: error), "\"apple\" already exists in the dictionary.")
        }

        do {
            _ = try await dictionary.addTerm(text: "App", aliases: ["apel"])
            XCTFail("Expected duplicate alias error")
        } catch {
            XCTAssertEqual(dictionary.errorMessage(for: error), "\"apel\" is already an alias for \"Apple\".")
        }

        try await dictionary.deleteTerm(id: apple.id)
        do {
            _ = try await dictionary.updateTerm(id: apple.id, text: "Edited", aliases: [])
            XCTFail("Expected missing term error")
        } catch {
            XCTAssertEqual(dictionary.errorMessage(for: error), "This term no longer exists.")
        }

        do {
            _ = try await dictionary.addTerm(text: String(repeating: "a", count: DictionaryTerm.maximumLength + 1), aliases: [])
            XCTFail("Expected textTooLong error")
        } catch {
            XCTAssertEqual(
                dictionary.errorMessage(for: error),
                "Term text must be \(DictionaryTerm.maximumLength) characters or fewer."
            )
        }

        let longAlias = String(repeating: "b", count: DictionaryTerm.maximumLength + 1)
        do {
            _ = try await dictionary.addTerm(text: "Valid", aliases: [longAlias])
            XCTFail("Expected aliasTooLong error")
        } catch {
            XCTAssertTrue(dictionary.errorMessage(for: error).contains("must be \(DictionaryTerm.maximumLength) characters or fewer."))
        }
    }

    func testTimeBudgetExceededPastesRawTextAndLogsReason() async throws {
        let seedStore = try MemoryStore(directory: directory)
        _ = try seedStore.addTerm(text: "Mac", aliases: ["MEC"])
        try seedStore.close()

        var logs: [String] = []
        let repository = SQLiteHistoryRepository(directory: directory)
        let history = DictationHistory(repository: FailingHistoryRepository(), notifications: FakeNotifications(), defaults: defaults, log: { _ in })
        let dictionary = UserDictionary(repository: repository, timeBudget: .zero, log: { logs.append($0) })
        let delivery = DictationDelivery(history: history, dictionary: dictionary)
        await dictionary.start().value

        var pasted: String?
        let delivered = try await delivery.deliver(
            rawText: "this MEC is fast",
            appBundleID: nil,
            appName: nil,
            modelID: "test",
            durationSeconds: 1.0
        ) { pasted = $0 }
        XCTAssertTrue(delivered)
        XCTAssertEqual(pasted, "this MEC is fast")
        XCTAssertEqual(logs.count, 1)
        XCTAssertTrue(logs[0].contains("time budget"))
    }

    func testLockedDatabaseRetriesWithBackoffAfterWriteLockClears() async throws {
        let seedStore = try MemoryStore(directory: directory)
        _ = try seedStore.addTerm(text: "Mac", aliases: ["MEC"])
        try seedStore.close()

        // Hold an exclusive SQLite write lock so MemoryStore.init fails with SQLITE_BUSY after busyTimeout.
        let lock = try ExclusiveSQLiteLock(path: directory.appending(path: "store.sqlite").path)
        defer { lock.release() }

        var logs: [String] = []
        let repository = SQLiteHistoryRepository(directory: directory, busyTimeout: 0.15)
        let history = DictationHistory(repository: FailingHistoryRepository(), notifications: FakeNotifications(), defaults: defaults, log: { _ in })
        let dictionary = UserDictionary(
            repository: repository,
            retryDelays: [.milliseconds(60), .milliseconds(120)],
            log: { logs.append($0) }
        )
        let delivery = DictationDelivery(history: history, dictionary: dictionary)

        // First attempt times out on the held lock without blocking future paste.
        await dictionary.start().value
        XCTAssertFalse(dictionary.isLoading)
        XCTAssertNotNil(dictionary.storeError)
        XCTAssertTrue(dictionary.storeError?.contains("locked") ?? false)
        XCTAssertTrue(dictionary.isRetryScheduled)
        XCTAssertEqual(logs.count, 1)

        var rawPasted: String?
        let pasteClock = ContinuousClock()
        let pasteStart = pasteClock.now
        _ = try await delivery.deliver(
            rawText: "this MEC is fast",
            appBundleID: nil,
            appName: nil,
            modelID: "test",
            durationSeconds: 1.0
        ) { rawPasted = $0 }
        XCTAssertLessThan(pasteStart.duration(to: pasteClock.now), .milliseconds(100))
        XCTAssertEqual(rawPasted, "this MEC is fast")

        // Release the exclusive write lock and let backoff retry reload the dictionary.
        lock.release()

        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while dictionary.storeError != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertNil(dictionary.storeError)
        XCTAssertFalse(dictionary.isRetrying)
        XCTAssertFalse(dictionary.isRetryScheduled)
        XCTAssertEqual(dictionary.terms.map(\.text), ["Mac"])

        var correctedPasted: String?
        _ = try await delivery.deliver(
            rawText: "this MEC is fast",
            appBundleID: nil,
            appName: nil,
            modelID: "test",
            durationSeconds: 1.0
        ) { correctedPasted = $0 }
        XCTAssertEqual(correctedPasted, "this Mac is fast")
    }

    func testNextDictationTriggersRetryImmediatelyWhileBackoffSleeps() async throws {
        let seedStore = try MemoryStore(directory: directory)
        _ = try seedStore.addTerm(text: "VoiceApp", aliases: ["voice app"])
        try seedStore.close()

        let lock = try ExclusiveSQLiteLock(path: directory.appending(path: "store.sqlite").path)
        defer { lock.release() }

        let repository = SQLiteHistoryRepository(directory: directory, busyTimeout: 0.1)
        let history = DictationHistory(repository: FailingHistoryRepository(), notifications: FakeNotifications(), defaults: defaults, log: { _ in })
        // Long initial backoff proves next dictation triggers immediate reload instead of waiting 60s.
        let dictionary = UserDictionary(
            repository: repository,
            retryDelays: [.seconds(60)],
            log: { _ in }
        )
        let delivery = DictationDelivery(history: history, dictionary: dictionary)

        await dictionary.start().value
        XCTAssertNotNil(dictionary.storeError)
        XCTAssertTrue(dictionary.isRetryScheduled)

        lock.release()

        // First dictation after unlock pastes raw immediately and kicks off immediate retry.
        var firstPasted: String?
        _ = try await delivery.deliver(
            rawText: "open voice app",
            appBundleID: nil,
            appName: nil,
            modelID: "test",
            durationSeconds: 1.0
        ) { firstPasted = $0 }
        XCTAssertEqual(firstPasted, "open voice app")

        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while dictionary.storeError != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(dictionary.storeError)
        XCTAssertEqual(dictionary.terms.map(\.text), ["VoiceApp"])

        var secondPasted: String?
        _ = try await delivery.deliver(
            rawText: "open voice app",
            appBundleID: nil,
            appName: nil,
            modelID: "test",
            durationSeconds: 1.0
        ) { secondPasted = $0 }
        XCTAssertEqual(secondPasted, "open VoiceApp")
    }
}

private final class ExclusiveSQLiteLock: @unchecked Sendable {
    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private let doneSemaphore = DispatchSemaphore(value: 0)
    private let stateLock = NSLock()
    private var released = false

    init(path: String) throws {
        let locker = try DatabaseQueue(path: path)
        let acquiredSemaphore = DispatchSemaphore(value: 0)
        final class LockedErrorBox: @unchecked Sendable {
            private let lock = NSLock()
            var error: Error?
            func set(_ error: Error) { lock.withLock { self.error = error } }
            func get() -> Error? { lock.withLock { error } }
        }
        let errorBox = LockedErrorBox()
        DispatchQueue.global().async { [releaseSemaphore, doneSemaphore] in
            defer {
                try? locker.close()
                doneSemaphore.signal()
            }
            do {
                try locker.writeWithoutTransaction { db in
                    try db.execute(sql: "BEGIN EXCLUSIVE")
                    acquiredSemaphore.signal()
                    releaseSemaphore.wait()
                    try db.execute(sql: "ROLLBACK")
                }
            } catch {
                errorBox.set(error)
                acquiredSemaphore.signal()
            }
        }
        acquiredSemaphore.wait()
        if let error = errorBox.get() { throw error }
    }

    func release() {
        stateLock.lock()
        let shouldRelease = !released
        if shouldRelease { released = true }
        stateLock.unlock()
        guard shouldRelease else { return }
        releaseSemaphore.signal()
        doneSemaphore.wait()
    }

    deinit {
        release()
    }
}

private struct DictionaryLoadFailure: LocalizedError {
    var errorDescription: String? { "Disk unreadable" }
}

private actor DictionaryGate {
    private var released = false
    nonisolated let entered = XCTestExpectation(description: "Open started")
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

private actor SpyDictionaryRepository: DictionaryRepository {
    private let backing: SQLiteHistoryRepository
    private var openFailure: Error?
    private var blockReads = false
    private var openGate: DictionaryGate?
    var listCount = 0

    init(backing: SQLiteHistoryRepository) {
        self.backing = backing
    }

    func failOpen(_ error: Error) { openFailure = error }
    func failAllReads(_ value: Bool) { blockReads = value }
    func setOpenGate(_ gate: DictionaryGate?) { openGate = gate }

    func open() async throws {
        await openGate?.enter()
        if let openFailure { throw openFailure }
        try await backing.open()
    }

    func listTerms() async throws -> [DictionaryTerm] {
        if blockReads { throw DictionaryLoadFailure() }
        listCount += 1
        return try await backing.listTerms()
    }

    func addTerm(text: String, aliases: [String]) async throws -> DictionaryTerm {
        try await backing.addTerm(text: text, aliases: aliases)
    }

    func updateTerm(id: UUID, text: String, aliases: [String]) async throws -> DictionaryTerm {
        try await backing.updateTerm(id: id, text: text, aliases: aliases)
    }

    func deleteTerm(id: UUID) async throws {
        try await backing.deleteTerm(id: id)
    }
}

private actor GatedHistoryRepository: HistoryRepository {
    func appendNote(_ note: CompletedDictation) async throws { throw CocoaError(.featureUnsupported) }
    func notes(query: String, remindersOnly: Bool, limit: Int) async throws -> [VoiceNote] { [] }
    func editNote(id: UUID, text: String) async throws { throw CocoaError(.featureUnsupported) }
    func setNoteDone(id: UUID, isDone: Bool) async throws { throw CocoaError(.featureUnsupported) }
    func setNoteReminder(id: UUID, date: Date?) async throws { throw CocoaError(.featureUnsupported) }
    func markNoteReminderNotified(id: UUID, at date: Date) async throws { throw CocoaError(.featureUnsupported) }

    private var openGate: DictionaryGate?
    var saved: [CompletedDictation] = []

    func setOpenGate(_ gate: DictionaryGate?) { openGate = gate }

    func open() async throws {
        await openGate?.enter()
    }

    func append(_ dictation: CompletedDictation) async throws -> MemoryRecord {
        saved.append(dictation)
        return MemoryRecord(
            id: dictation.id,
            deviceID: UUID(),
            kind: .dictation,
            createdAt: dictation.createdAt,
            rawText: dictation.rawText,
            finalText: dictation.finalText,
            appBundleID: dictation.appBundleID,
            appName: dictation.appName,
            project: nil,
            modelID: dictation.modelID,
            durationSeconds: dictation.durationSeconds,
            audioPath: nil,
            deletedAt: nil
        )
    }

    func records(query: String, limit: Int) async throws -> [MemoryRecord] { [] }
    func delete(ids: [UUID]) async throws {}
    func deleteAll() async throws {}
}

private struct FailingHistoryRepository: HistoryRepository {
    func appendNote(_ note: CompletedDictation) async throws { throw CocoaError(.featureUnsupported) }
    func notes(query: String, remindersOnly: Bool, limit: Int) async throws -> [VoiceNote] { [] }
    func editNote(id: UUID, text: String) async throws { throw CocoaError(.featureUnsupported) }
    func setNoteDone(id: UUID, isDone: Bool) async throws { throw CocoaError(.featureUnsupported) }
    func setNoteReminder(id: UUID, date: Date?) async throws { throw CocoaError(.featureUnsupported) }
    func markNoteReminderNotified(id: UUID, at date: Date) async throws { throw CocoaError(.featureUnsupported) }

    func open() async throws { throw DictionaryLoadFailure() }
    func append(_ dictation: CompletedDictation) async throws -> MemoryRecord { throw DictionaryLoadFailure() }
    func records(query: String, limit: Int) async throws -> [MemoryRecord] { [] }
    func delete(ids: [UUID]) async throws {}
    func deleteAll() async throws {}
}
