import XCTest
@testable import VoiceAppCore

final class ShortcutValidationTests: XCTestCase {
    func testEveryNoteDictationPairRejectsConflictInBothDirectionsAndKeepsPrevious() {
        // The four recorder positions: dictation hold/toggle, note hold/toggle.
        let bindings = ["option-space", "option-shift-space", "command-1", "command-2"]
        for changed in bindings.indices {
            for other in bindings.indices where changed != other {
                let result = ShortcutValidation.resolve(candidate: bindings[other], previous: bindings[changed],
                    others: bindings.indices.filter { $0 != changed }.map { bindings[$0] })
                XCTAssertEqual(result.value, bindings[changed])
                XCTAssertEqual(result.message, "That shortcut is already used. Choose a different combination.")
            }
        }
        XCTAssertEqual(ShortcutValidation.resolve(candidate: "new", previous: "old", others: ["other"]).value, "new")
        let cleared = ShortcutValidation.resolve(candidate: nil, previous: "old", others: ["other", nil])
        XCTAssertNil(cleared.value)
        XCTAssertNil(cleared.message)
    }
}
