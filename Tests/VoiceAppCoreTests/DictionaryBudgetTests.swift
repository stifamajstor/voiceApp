import Foundation
@testable import VoiceAppCore
import XCTest

final class DictionaryBudgetTests: XCTestCase {
    private func term(_ text: String, _ aliases: [String] = []) -> DictionaryTerm {
        DictionaryTerm(text: text, aliases: aliases, deviceID: UUID())
    }

    func testSchedulerDelayDoesNotConsumeDefaultCPUBudget() {
        let matcher = CorrectionMatcher(terms: [term("Mac", ["MEC"])])
        var reads = 0
        let result = matcher.correct("this MEC is fast", now: {
            reads += 1
            if reads == 2 { Thread.sleep(forTimeInterval: 0.08) }
            return CorrectionMatcher.threadCPUTime()
        })
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.text, "this Mac is fast")
    }

    func testLongDictationGetsMoreThanFiftyMillisecondsOfCPU() {
        let input = String(repeating: "ordinary ", count: 1_000) + "MEC"
        let matcher = CorrectionMatcher(terms: [term("Mac", ["MEC"])])
        var reads = 0
        let result = matcher.correct(input, now: {
            reads += 1
            return reads == 1 ? .zero : .milliseconds(60)
        })
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.text, String(input.dropLast(3)) + "Mac")
    }

    func testCandidateTraversalHonorsDeadlineWithoutAnyCompletedMatch() {
        // Many deep trie walks, but no terminal matches: checking only before/after
        // candidate collection cannot interrupt this work.
        let matcher = CorrectionMatcher(terms: [term(String(repeating: "a ", count: 49) + "z")])
        let input = Array(repeating: "a", count: 200).joined(separator: " ")
        var ticks = 0
        let start = Duration.zero
        let result = matcher.correct(input, timeBudget: .milliseconds(50)) {
            ticks += 1
            return start + (ticks < 20 ? .zero : .milliseconds(60))
        }
        XCTAssertTrue(result.timedOut)
        XCTAssertEqual(result.text, input)
        XCTAssertEqual(result.replacements, [])
    }

    func testCombiningMarkInflationIsRejectedAndLegacyValuesAreSkipped() throws {
        let padded = String(repeating: "x\u{301}", count: 99)
        XCTAssertEqual(padded.count, 99)
        XCTAssertTrue(DictionaryTerm.exceedsLengthLimit(padded))
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try MemoryStore(directory: directory)
        defer { try? store.close() }
        XCTAssertThrowsError(try store.addTerm(text: padded))
        XCTAssertThrowsError(try store.addTerm(text: "Valid", aliases: [padded]))
        let valid = try store.addTerm(text: "Mac", aliases: ["MEC"])
        XCTAssertThrowsError(try store.updateTerm(id: valid.id, text: padded, aliases: []))
        XCTAssertThrowsError(try store.updateTerm(id: valid.id, text: "Mac", aliases: [padded]))
        XCTAssertEqual(try store.dictionaryTerm(id: valid.id), valid)
        let result = correctText("the MEC \(padded)", terms: [term(padded, ["the"]), term("Mac", [padded, "MEC"])])
        XCTAssertEqual(result.text, "the Mac \(padded)")
        XCTAssertEqual(result.replacements.map(\.original), ["MEC"])
        let boundary = String(repeating: "x\u{301}", count: 50)
        XCTAssertFalse(DictionaryTerm.exceedsLengthLimit(boundary))
        XCTAssertNoThrow(try store.addTerm(text: boundary))
    }

    func testNestedCandidatesAreCappedEvenWithoutADeadline() {
        let terms = (1...50).map { count in
            term(Array(repeating: "a", count: count).joined(separator: " "), count == 50 ? ["b"] : [])
        }
        let input = Array(repeating: "b", count: 200).joined(separator: " ")
        let result = correctText(input, terms: terms, timeBudget: nil)
        XCTAssertTrue(result.timedOut)
        XCTAssertFalse(result.converged)
        XCTAssertEqual(result.text, input)
        XCTAssertEqual(result.replacements, [])
    }

    func testShorterCandidateStillFitsWhenLongestAtSameStartIsBlocked() {
        // "b c d e" wins globally. "a b" then overlaps it, but "a" still fits.
        let result = correctText("a b c d e", terms: [term("X", ["a"]), term("Y", ["a b"]), term("Z", ["b c d e"])])
        XCTAssertEqual(result.text, "X Z")
    }
}
