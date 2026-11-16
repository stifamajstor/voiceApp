import XCTest
@testable import VoiceAppCore

@MainActor
final class CloudCorrectionTerminationTests: XCTestCase {
    func testQuitWaitsForCorrectionAndDurableSaveWithoutPasting() async throws {
        try await withPipeline { history, delivery, correction, directory in
            var isQuitting = false
            let task = Task {
                _ = try? await delivery.deliver(rawText: "I would load it.", appBundleID: nil,
                    appName: nil, modelID: "test", durationSeconds: 1) { _ in
                    if !isQuitting { XCTFail("Quit must suppress paste") }
                }
            }
            await self.fulfillment(of: [correction.gate.entered], timeout: 2)
            XCTAssertNil(history.pendingSave)
            var replies = 0
            let replied = self.expectation(description: "delivery saved before quit")
            let termination = HistoryTermination(history: history, pendingTranscription: { task },
                prepareToQuit: { isQuitting = true })
            XCTAssertFalse(termination.requestTermination { success in
                replies += 1
                XCTAssertTrue(success)
                XCTAssertNil(history.pendingSave)
                do {
                    let store = try MemoryStore(directory: directory)
                    defer { try? store.close() }
                    XCTAssertEqual(try store.listRecent(kind: .dictation).map(\.finalText), ["I would love it."])
                } catch { XCTFail("Quit replied before durable save: \(error)") }
                replied.fulfill()
            })
            XCTAssertTrue(isQuitting)
            XCTAssertFalse(termination.requestTermination { _ in XCTFail("Repeated Quit replied") })
            termination.requestQuit { XCTFail("Repeated menu Quit called terminate") }
            XCTAssertEqual(replies, 0)
            correction.gate.release()
            await task.value
            await self.fulfillment(of: [replied], timeout: 2)
            XCTAssertEqual(replies, 1)
        }
    }

    func testTranscriptionCorrectionAndSaveShareOneQuitDeadline() async throws {
        try await withPipeline { history, delivery, correction, _ in
            let transcriptionGate = IntegrationGate()
            let deadlineGate = IntegrationGate()
            let task = Task {
                await transcriptionGate.wait()
                _ = try? await delivery.deliver(rawText: "I would load it.", appBundleID: nil,
                    appName: nil, modelID: "test", durationSeconds: 1) { _ in }
            }
            await self.fulfillment(of: [transcriptionGate.entered], timeout: 2)
            var replies = 0
            let termination = HistoryTermination(history: history, pendingTranscription: { task },
                waitForDeadline: { duration in
                    XCTAssertEqual(duration, .seconds(30))
                    await deadlineGate.wait()
                })
            let replied = self.expectation(description: "single overall deadline")
            XCTAssertFalse(termination.requestTermination { success in
                XCTAssertTrue(success)
                replies += 1
                replied.fulfill()
            })
            await self.fulfillment(of: [deadlineGate.entered], timeout: 2)
            transcriptionGate.release()
            await self.fulfillment(of: [correction.gate.entered], timeout: 2)
            XCTAssertEqual(replies, 0)
            let draining = termination.waiting
            deadlineGate.release()
            await self.fulfillment(of: [replied], timeout: 2)
            correction.gate.release()
            await task.value
            await history.pendingSave?.value
            await draining?.value
            XCTAssertEqual(replies, 1)
        }
    }

    private func withPipeline(_ body: (DictationHistory, DictationDelivery,
                                      SuspendedCorrection, URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "CloudQuit-\(UUID())")
        let name = "CloudQuit.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: directory)
        }
        let repository = SQLiteHistoryRepository(directory: directory)
        let history = DictationHistory(repository: repository, notifications: FakeNotifications(), defaults: defaults)
        let dictionary = UserDictionary(repository: repository)
        let correction = SuspendedCorrection()
        let delivery = DictationDelivery(history: history, dictionary: dictionary, cloudCorrection: correction)
        await history.start().value
        await dictionary.start().value
        try await body(history, delivery, correction, directory)
    }
}

@MainActor
private final class SuspendedCorrection: CloudCorrecting {
    let gate = IntegrationGate()

    func correct(_ text: String, dictionaryTerms: [String], protectedRanges: [Range<String.Index>],
                 appBundleID: String?, appName: String?) async -> CorrectionOutcome {
        await gate.wait()
        return CorrectionOutcome(inputText: text, outputText: "I would love it.",
            provider: .anthropic, modelID: "test", status: .applied)
    }
}

@MainActor
private final class IntegrationGate {
    let entered = XCTestExpectation(description: "work suspended")
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation = $0; entered.fulfill() }
    }

    func release() { continuation?.resume(); continuation = nil }
}
