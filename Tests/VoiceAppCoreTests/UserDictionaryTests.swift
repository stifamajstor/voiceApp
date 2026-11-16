import Foundation
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
        let history = DictationHistory(repository: repository, defaults: defaults)
        let dictionary = UserDictionary(repository: repository)
        await history.start().value
        await dictionary.start().value

        try await dictionary.addTerm(text: "Mac", aliases: ["MEC", "Meg"])
        let rawText = "this MEC is fast"
        let corrected = dictionary.correct(rawText)
        XCTAssertEqual(corrected.text, "this Mac is fast")

        let dictation = CompletedDictation(
            rawText: rawText,
            finalText: corrected.text,
            appBundleID: "com.apple.TextEdit",
            appName: "TextEdit",
            modelID: "parakeet-tdt-0.6b-v3",
            durationSeconds: 1.5
        )
        var pasted: String?
        await history.deliver(dictation) { text in
            pasted = text
        }
        XCTAssertEqual(pasted, "this Mac is fast")
        await history.pendingSave?.value

        let store = try MemoryStore(directory: directory)
        defer { try? store.close() }
        let saved = try XCTUnwrap(store.listRecent(kind: .dictation, limit: 1).first)
        XCTAssertEqual(saved.rawText, "this MEC is fast")
        XCTAssertEqual(saved.finalText, "this Mac is fast")
        XCTAssertEqual(try store.search("MEC").map(\.id), [saved.id])
        XCTAssertEqual(try store.search("Mac").map(\.id), [saved.id])
    }

    func testEditsAndDeletesTakeEffectOnNextDictationWithoutReadingStore() async throws {
        let initial = DictionaryTerm(text: "Mac", aliases: ["MEC", "Meg"], deviceID: UUID())
        let repository = SpyDictionaryRepository(initialTerms: [initial])
        let dictionary = UserDictionary(repository: repository)
        await dictionary.start().value

        let initialReads = await repository.listCount
        XCTAssertEqual(initialReads, 1)

        // Block any future store access to prove correction runs purely in memory.
        await repository.failAllReads(true)
        XCTAssertEqual(dictionary.correct("this MEC is fast").text, "this Mac is fast")
        XCTAssertEqual(dictionary.correct("tell Meg hello").text, "tell Mac hello")
        let readsAfterCorrection = await repository.listCount
        XCTAssertEqual(readsAfterCorrection, 1)

        await repository.failAllReads(false)
        let edited = try await dictionary.updateTerm(id: initial.id, text: "MacBook", aliases: ["MEC", "Meg"])
        XCTAssertEqual(edited.text, "MacBook")
        XCTAssertEqual(dictionary.correct("this MEC is fast").text, "this MacBook is fast")

        try await dictionary.deleteTerm(id: initial.id)
        XCTAssertEqual(dictionary.correct("this MEC is fast").text, "this MEC is fast")
        XCTAssertTrue(dictionary.terms.isEmpty)
        let finalReads = await repository.listCount
        XCTAssertEqual(finalReads, 1)
    }

    func testStoreFailureStillPastesRawTextAndLogsReason() async {
        let repository = SpyDictionaryRepository(initialTerms: [])
        await repository.failOpen(DictionaryLoadFailure())
        var logs: [String] = []
        let dictionary = UserDictionary(repository: repository, log: { logs.append($0) })
        let history = DictationHistory(repository: FailingHistoryRepository(), defaults: defaults, log: { _ in })

        await dictionary.start().value
        XCTAssertNotNil(dictionary.storeError)
        XCTAssertEqual(logs.count, 1)
        XCTAssertTrue(logs[0].contains("Disk unreadable"))

        let raw = "this MEC is fast"
        let corrected = dictionary.correct(raw)
        let dictation = CompletedDictation(
            rawText: raw,
            finalText: corrected.text,
            appBundleID: nil,
            appName: nil,
            modelID: "parakeet-tdt-0.6b-v3",
            durationSeconds: 1.0
        )
        var pasted: String?
        await history.deliver(dictation) { pasted = $0 }
        XCTAssertEqual(pasted, "this MEC is fast")
    }

    func testSlowLoadDoesNotBlockCorrectionAndAppliesOnceFinished() async {
        let term = DictionaryTerm(text: "Mac", aliases: ["MEC"], deviceID: UUID())
        let repository = SpyDictionaryRepository(initialTerms: [term])
        let gate = DictionaryGate()
        await repository.setOpenGate(gate)
        let dictionary = UserDictionary(repository: repository)

        let loading = dictionary.start()
        await fulfillment(of: [gate.entered], timeout: 2)
        XCTAssertTrue(dictionary.isLoading)
        XCTAssertEqual(dictionary.correct("this MEC is fast").text, "this MEC is fast")

        await gate.release()
        await loading.value
        XCTAssertFalse(dictionary.isLoading)
        XCTAssertEqual(dictionary.correct("this MEC is fast").text, "this Mac is fast")
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
    private var terms: [UUID: DictionaryTerm]
    private var openFailure: Error?
    private var blockReads = false
    private var openGate: DictionaryGate?
    var listCount = 0

    init(initialTerms: [DictionaryTerm]) {
        terms = Dictionary(uniqueKeysWithValues: initialTerms.map { ($0.id, $0) })
    }

    func failOpen(_ error: Error) { openFailure = error }
    func failAllReads(_ value: Bool) { blockReads = value }
    func setOpenGate(_ gate: DictionaryGate?) { openGate = gate }

    func open() async throws {
        await openGate?.enter()
        if let openFailure { throw openFailure }
    }

    func listTerms() async throws -> [DictionaryTerm] {
        if blockReads { throw DictionaryLoadFailure() }
        listCount += 1
        return Array(terms.values)
    }

    func addTerm(text: String, aliases: [String]) async throws -> DictionaryTerm {
        let term = DictionaryTerm(text: text, aliases: aliases, deviceID: UUID())
        terms[term.id] = term
        return term
    }

    func updateTerm(id: UUID, text: String, aliases: [String]) async throws -> DictionaryTerm {
        guard var term = terms[id] else { throw DictionaryError.termNotFound(id) }
        term.text = text
        term.aliases = aliases
        terms[id] = term
        return term
    }

    func deleteTerm(id: UUID) async throws {
        terms.removeValue(forKey: id)
    }
}

private struct FailingHistoryRepository: HistoryRepository {
    func open() async throws { throw DictionaryLoadFailure() }
    func append(_ dictation: CompletedDictation) async throws -> MemoryRecord { throw DictionaryLoadFailure() }
    func records(query: String, limit: Int) async throws -> [MemoryRecord] { [] }
    func delete(ids: [UUID]) async throws {}
    func deleteAll() async throws {}
}
