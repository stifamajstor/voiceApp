import Foundation
import VoiceAppCore
import XCTest

final class DictionaryReferenceTests: XCTestCase {
    func testRandomizedLongestMatchAndFixedPointAgainstLiteralReference() {
        var state: UInt64 = 20261116
        func next(_ count: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 32) % UInt64(count))
        }
        func phrase() -> String {
            (0..<(1 + next(4))).map { _ in ["a", "b", "c", "d"][next(4)] }.joined(separator: " ")
        }
        for _ in 0..<400 {
            let terms = (0..<(1 + next(7))).map { _ in
                DictionaryTerm(text: phrase(), aliases: [phrase(), phrase()], deviceID: UUID())
            }
            let input = phrase() + " " + phrase() + " " + phrase()
            let expected = reference(input, terms: terms)
            let actual = correctText(input, terms: terms, timeBudget: nil)
            XCTAssertEqual(actual.text, expected.text, "input=\(input), terms=\(terms)")
            XCTAssertEqual(actual.converged, expected.converged)
            let rebuilt = NSMutableString(string: input)
            for edit in actual.replacements.reversed() {
                XCTAssertEqual((input as NSString).substring(with: edit.range), edit.original)
                rebuilt.replaceCharacters(in: edit.range, with: edit.replacement)
            }
            XCTAssertEqual(rebuilt as String, expected.text)
        }
    }

    // Deliberately brute-force and word-based: independent of trie normalization,
    // candidate limits, source tracking and the production sorting helper.
    private func reference(_ input: String, terms: [DictionaryTerm]) -> (text: String, converged: Bool) {
        func pass(_ input: String) -> String {
            let words = input.split(separator: " ").map(String.init)
            var matches: [(start: Int, end: Int, length: Int, term: DictionaryTerm)] = []
            for start in words.indices {
                for end in (start + 1)...words.count {
                    let phrase = words[start..<end].joined(separator: " ")
                    for term in terms where ([term.text] + term.aliases).contains(phrase) {
                        matches.append((start, end, phrase.utf16.count, term))
                    }
                }
            }
            matches.sort {
                if $0.length != $1.length { return $0.length > $1.length }
                if $0.start != $1.start { return $0.start < $1.start }
                if $0.term.id != $1.term.id { return $0.term.id.uuidString < $1.term.id.uuidString }
                return $0.term.text.utf8.lexicographicallyPrecedes($1.term.text.utf8)
            }
            var occupied = Set<Int>()
            var selected: [Int: (end: Int, text: String)] = [:]
            for match in matches where occupied.isDisjoint(with: match.start..<match.end) {
                occupied.formUnion(match.start..<match.end)
                selected[match.start] = (match.end, match.term.text)
            }
            var result: [String] = []
            var cursor = 0
            while cursor < words.count {
                if let match = selected[cursor] {
                    result.append(match.text)
                    cursor = match.end
                } else {
                    result.append(words[cursor])
                    cursor += 1
                }
            }
            return result.joined(separator: " ")
        }
        var output = input
        for _ in 0..<8 {
            let next = pass(output)
            if next == output { return (output, true) }
            output = next
        }
        return (output, pass(output) == output)
    }
}
