import XCTest
@testable import VoiceAppCore

@MainActor
final class TranscriptionTerminationTests: XCTestCase {
    func testQuitWaitsForNoteAndDictationTranscriptionThenTheirActualSave() async throws {
        for destination in [CaptureDestination.note, .dictation] {
            let directory = FileManager.default.temporaryDirectory.appending(path: "QuitTranscription-\(UUID())")
            let name = "QuitTranscription.\(UUID())"
            let defaults = UserDefaults(suiteName: name)!
            let repository = SQLiteHistoryRepository(directory: directory)
            let history = DictationHistory(repository: repository, notifications: FakeNotifications(), defaults: defaults)
            await history.start().value
            let gate = TranscriptionGate()
            var task: Task<Void, Never>?
            task = Task {
                defer { task = nil }
                await gate.wait()
                let result = CompletedDictation(rawText: "raw", finalText: "saved during quit",
                    appBundleID: nil, appName: nil, modelID: "test", durationSeconds: 1)
                await history.deliver(result, destination: destination) { _ in }
            }
            await fulfillment(of: [gate.entered], timeout: 2)
            // Transcription has not queued a save yet: this is the previously unprotected gap.
            XCTAssertNil(history.pendingSave)
            let termination = HistoryTermination(history: history, pendingTranscription: { task })
            let replied = expectation(description: "quit after transcription and persistence")
            XCTAssertFalse(termination.requestTermination { success in
                XCTAssertTrue(success)
                XCTAssertNil(history.pendingSave)
                do {
                    let saved = try MemoryStore(directory: directory)
                    defer { try? saved.close() }
                    if destination == .note { XCTAssertEqual(try saved.notes().map(\.text), ["saved during quit"]) }
                    else { XCTAssertEqual(try saved.listRecent(kind: .dictation).map(\.finalText), ["saved during quit"]) }
                } catch { XCTFail("Quit replied before durable save: \(error)") }
                replied.fulfill()
            })
            XCTAssertTrue(termination.isQuitPending)
            await gate.release()
            await task?.value
            await fulfillment(of: [replied], timeout: 2)
            let store = try MemoryStore(directory: directory)
            if destination == .note { XCTAssertEqual(try store.notes().map(\.text), ["saved during quit"]) }
            else { XCTAssertEqual(try store.listRecent(kind: .dictation).map(\.finalText), ["saved during quit"]) }
            try store.close()
            defaults.removePersistentDomain(forName: name)
            try FileManager.default.removeItem(at: directory)
        }
    }

    func testTranscriptionAndSaveShareOneThirtySecondDeadline() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "QuitDeadline-\(UUID())")
        let name = "QuitDeadline.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: directory)
        }
        let history = DictationHistory(repository: SQLiteHistoryRepository(directory: directory),
            notifications: FakeNotifications(), defaults: defaults)
        await history.start().value
        let transcriptionGate = TranscriptionGate()
        let deadlineGate = TranscriptionGate()
        let task = Task { await transcriptionGate.wait() }
        await fulfillment(of: [transcriptionGate.entered], timeout: 2)
        let termination = HistoryTermination(history: history, pendingTranscription: { task }, waitForDeadline: { duration in
            XCTAssertEqual(duration, .seconds(30))
            await deadlineGate.wait()
        })
        var replies = 0
        let replied = expectation(description: "deadline replies while transcription is still suspended")
        XCTAssertFalse(termination.requestTermination { success in
            XCTAssertTrue(success)
            replies += 1
            replied.fulfill()
        })
        await fulfillment(of: [deadlineGate.entered], timeout: 2)
        XCTAssertEqual(replies, 0)
        await deadlineGate.release()
        await fulfillment(of: [replied], timeout: 2)
        XCTAssertFalse(task.isCancelled)
        await transcriptionGate.release()
        await task.value
        await termination.waiting?.value
        XCTAssertEqual(replies, 1)
    }

}

private actor TranscriptionGate {
    nonisolated let entered = XCTestExpectation(description: "transcription in flight")
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        await withCheckedContinuation { continuation = $0; entered.fulfill() }
    }
    func release() { continuation?.resume(); continuation = nil }
}
