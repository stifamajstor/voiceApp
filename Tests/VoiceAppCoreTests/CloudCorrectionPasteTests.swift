import AppKit
import XCTest
@testable import VoiceApp
@testable import VoiceAppCore

@MainActor
final class CloudCorrectionPasteTests: XCTestCase {
    func testAppSwitchDuringModifierWaitCopiesAndSavesAsClipboard() async throws {
        try await assertClipboardFallback(switchDuringCorrection: false)
    }

    func testAppSwitchDuringCloudCorrectionCopiesAndSavesAsClipboard() async throws {
        try await assertClipboardFallback(switchDuringCorrection: true)
    }

    private func assertClipboardFallback(switchDuringCorrection: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let suite = "PasteTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let repository = SQLiteHistoryRepository(directory: directory)
        let history = DictationHistory(repository: repository, notifications: FakeNotifications(), defaults: defaults)
        var frontmost: pid_t = 123
        let correction = AppSwitchCorrection {
            if switchDuringCorrection { frontmost = 456 }
        }
        let delivery = DictationDelivery(history: history, dictionary: UserDictionary(repository: repository),
                                         cloudCorrection: correction)
        await history.start().value
        let pasteboard = NSPasteboard(name: .init(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        var posts = 0
        do {
            _ = try await delivery.deliver(rawText: "Keep this dictation safe", appBundleID: "com.example.target",
                appName: "Original target", modelID: "test", durationSeconds: 1) { text in
                try await TextInserter.insert(text, targetProcessID: 123, pasteboard: pasteboard,
                    frontmostProcessID: { frontmost }, accessibilityGranted: { true },
                    waitForModifiers: { if !switchDuringCorrection { frontmost = 456 } }, sendPaste: { posts += 1; return true })
            }
            XCTFail("Expected clipboard fallback notice")
        } catch {
            XCTAssertTrue(error is DictationDelivery.TargetChanged)
            XCTAssertEqual(error.localizedDescription, "Copied to clipboard — the target app changed")
        }
        XCTAssertEqual(posts, 0)
        XCTAssertEqual(pasteboard.string(forType: .string), "Keep this dictation safe")
        await history.pendingSave?.value
        let saved = try await repository.records(query: "", limit: 1)
        XCTAssertEqual(saved.first?.appName, "Clipboard")
        XCTAssertNil(saved.first?.appBundleID)
        XCTAssertEqual(saved.first?.finalText, "Keep this dictation safe")
    }

    func testSameTargetPastesAndMissingTargetFallsBack() async throws {
        let pasteboard = NSPasteboard(name: .init(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        var posts = 0
        try await TextInserter.insert("same target", keepOnClipboard: true, targetProcessID: 123, pasteboard: pasteboard,
            frontmostProcessID: { 123 }, accessibilityGranted: { true }, waitForModifiers: {},
            sendPaste: { posts += 1; return true })
        XCTAssertEqual(posts, 1)
        do {
            try await TextInserter.insert("missing target", targetProcessID: nil, pasteboard: pasteboard,
                frontmostProcessID: { 123 }, accessibilityGranted: { true }, waitForModifiers: {},
                sendPaste: { posts += 1; return true })
            XCTFail("An unknown target must not receive a paste")
        } catch { XCTAssertTrue(error is DictationDelivery.TargetChanged) }
        XCTAssertEqual(posts, 1)
    }
}

@MainActor
private final class AppSwitchCorrection: CloudCorrecting {
    let switchApp: () -> Void
    init(switchApp: @escaping () -> Void) { self.switchApp = switchApp }

    func correct(_ text: String, dictionaryTerms: [String], protectedRanges: [Range<String.Index>],
                 appBundleID: String?, appName: String?) async -> CorrectionOutcome {
        XCTAssertEqual(appBundleID, "com.example.target")
        switchApp()
        return CorrectionOutcome(outputText: text, status: .unchanged)
    }
}
