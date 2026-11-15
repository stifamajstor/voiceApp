import Foundation
import XCTest

/// Source wiring checks complement the coordinator tests without starting the app or its hotkeys.
final class HistoryInterfaceTests: XCTestCase {
    private func source(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appending(path: "Sources/VoiceApp/\(name).swift"))
    }

    func testMenuExplainsLocalSavingInBothStates() throws {
        let menu = try source("MenuBarView")
        XCTAssertTrue(menu.contains("history.saveEnabled"))
        XCTAssertTrue(menu.contains("Dictations are saved on this Mac. Turn off in Settings → Behavior."))
        XCTAssertTrue(menu.contains("New dictations are not saved. Turn on in Settings → Behavior."))
    }

    func testHistoryRowsLimitPreviewAndCopyFullTranscript() throws {
        let view = try source("HistoryView")
        let transcript = try XCTUnwrap(view.range(of: "Text(record.finalText)"))
        let copy = try XCTUnwrap(view.range(of: "TextInserter.copy(record.finalText)"))
        XCTAssertTrue(view[transcript.upperBound..<copy.lowerBound].contains(".lineLimit(3)"))
    }

    func testKeyboardAndButtonRequestSelectedDeleteConfirmation() throws {
        let view = try source("HistoryView")
        let keyboard = try XCTUnwrap(view.range(of: ".onDeleteCommand"))
        let buttons = try XCTUnwrap(view.range(of: "HStack {", range: keyboard.upperBound..<view.endIndex))
        XCTAssertTrue(view[keyboard.upperBound..<buttons.lowerBound].contains("history.requestDeleteSelected()"))
        XCTAssertEqual(view.components(separatedBy: "history.requestDeleteSelected()").count - 1, 2)
        XCTAssertTrue(view.contains("history.selectedDeleteCount"))
        XCTAssertTrue(view.contains("history.deleteAllCount"))
    }

    func testAllQuitRequestsUseApplicationDelegateGuard() throws {
        let app = try source("App")
        XCTAssertTrue(app.contains("@NSApplicationDelegateAdaptor"))
        XCTAssertTrue(app.contains("applicationShouldTerminate"))
        XCTAssertTrue(app.contains("requestTermination"))
        XCTAssertTrue(app.contains("reply(toApplicationShouldTerminate:"))
    }
}
