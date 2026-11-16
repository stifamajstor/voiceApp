import Foundation
import XCTest
@testable import VoiceAppCore

@MainActor
final class CloudCorrectionBlockerTests: XCTestCase {
    func testRejectsNewInvisibleScalarsAndNonSpaceWhitespace() throws {
        for scalar in [0x200B, 0x200D, 0x200C, 0x202E, 0x2066, 0x2069, 0xFEFF, 0x00AD,
                       0xE0041, 0x180E, 0x034F, 0xFE0F, 0x00A0, 0x202F, 0x2007] {
            let replacement = "sta" + String(Unicode.Scalar(scalar)!) + "tus"
            XCTAssertThrowsError(try CorrectionEditValidator.apply(
                [CorrectionEdit(original: "status", replacement: replacement)],
                to: "please run git status now"), "Accepted U+\(String(scalar, radix: 16))")
        }
        XCTAssertThrowsError(try CorrectionEditValidator.apply(
            [CorrectionEdit(original: "git status", replacement: "git\u{A0}status")],
            to: "please run git status now"))
    }

    func testRejectsLeadingExtendersThatAlterThePreviousGrapheme() throws {
        for scalar in [0x301, 0x200D, 0x200C, 0xFE0F, 0xE0041] {
            XCTAssertThrowsError(try CorrectionEditValidator.apply(
                [CorrectionEdit(original: "北京看看", replacement: String(Unicode.Scalar(scalar)!) + "北京看看")],
                to: "我想去北京看看"))
            XCTAssertThrowsError(try CorrectionEditValidator.apply(
                [CorrectionEdit(original: "bold", replacement: String(Unicode.Scalar(scalar)!) + "bold")],
                to: "please make *bold* text now"))
        }
    }

    func testWholeTextDiffCountsAllWordsMergedAcrossEditEdges() throws {
        XCTAssertThrowsError(try CorrectionEditValidator.apply(
            [CorrectionEdit(original: "* to #", replacement: "love")], to: " *bold* to #tag ")) { error in
            XCTAssertEqual(error as? EditValidationError,
                           .excessiveChanges(changedWords: 3, totalWords: 3, maxAllowed: 1))
        }
        // Independent edits must not count the untouched words between them.
        XCTAssertEqual(try CorrectionEditValidator.apply([
            CorrectionEdit(original: "one", replacement: "1"),
            CorrectionEdit(original: "five", replacement: "5")
        ], to: "one two three four five"), "1 two three four 5")
    }

    func testExistingEmojiSequenceAndDiacriticsRemainUsable() throws {
        XCTAssertEqual(try CorrectionEditValidator.apply([
            CorrectionEdit(original: "load 👩‍👧", replacement: "love 👩‍👧")
        ], to: "I would load 👩‍👧 today"), "I would love 👩‍👧 today")
        XCTAssertEqual(try CorrectionEditValidator.apply([
            CorrectionEdit(original: "Zagreb", replacement: "Zadar")
        ], to: "Idem u Zagreb sutra"), "Idem u Zadar sutra")
    }
}
