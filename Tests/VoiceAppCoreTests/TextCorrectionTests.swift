import Foundation
import VoiceAppCore
import XCTest

final class TextCorrectionTests: XCTestCase {
    private func term(_ text: String, _ aliases: [String] = [], id: UUID = UUID()) -> DictionaryTerm {
        DictionaryTerm(id: id, text: text, aliases: aliases, updatedAt: Date(timeIntervalSince1970: 100), deviceID: UUID())
    }

    func testSpikeCasesAndCaseInsensitiveCanonicalSpelling() {
        let terms = [term("ChatGPT", ["chat GPT"]), term("VoiceApp", ["Voice app"]),
            term("Tailscale", ["Tail scale"]), term("T3 Code", ["T3 code"]), term("Codex")]
        let result = correctText("chat GPT, Voice app; Tail scale / T3 code and codex.", terms: terms)
        XCTAssertEqual(result.text, "ChatGPT, VoiceApp; Tailscale / T3 Code and Codex.")
        XCTAssertEqual(result.replacements.count, 5)
        XCTAssertTrue(result.converged)
        XCTAssertEqual(correctText(result.text, terms: terms).replacements, [])
    }

    func testWholeWordsUnicodeJoinersAndPunctuation() {
        let input = "Mac machine Macintosh äMac Macß čMac Macć žMac Macš đMac Macž _Mac Mac2 Mac's Mac’s Mac-based pre-Mac pre’Mac Mac‑based 'Mac' (Mac),Mac!"
        let result = correctText(input, terms: [term("Computer", ["Mac"])])
        XCTAssertEqual(result.text, "Computer machine Macintosh äMac Macß čMac Macć žMac Macš đMac Macž _Mac Mac2 Mac's Mac’s Mac-based pre-Mac pre’Mac Mac‑based 'Computer' (Computer),Computer!")
        XCTAssertEqual(correctText("ČĆŽŠĐ ÄÖÜ STRASSE", terms: [term("Croatian", ["čćžšđ"]), term("German", ["äöü"]), term("Street", ["straße"])]).text, "Croatian German Street")
    }

    func testWhitespaceRunsAndExactOutsideBytesAndInputRanges() {
        let input = "👩🏽‍💻\te\u{301}\r\nchat  \tGPT\u{a0}❤️ chat\nGPT!\0"
        let result = correctText(input, terms: [term("ChatGPT", ["chat GPT"])])
        XCTAssertEqual(Array(result.text.utf8), Array("👩🏽‍💻\te\u{301}\r\nChatGPT\u{a0}❤️ ChatGPT!\0".utf8))
        XCTAssertEqual(result.replacements.map(\.original), ["chat  \tGPT", "chat\nGPT"])
        for replacement in result.replacements {
            XCTAssertEqual((input as NSString).substring(with: replacement.range), replacement.original)
            XCTAssertEqual(replacement.replacement, "ChatGPT")
        }
    }

    func testLongestOverlapWinsEvenWhenItStartsLaterAndTiesAreStable() {
        let first = term("Short", ["one two"])
        let second = term("Long", ["two three four"])
        let input = "one two three four"
        XCTAssertEqual(correctText(input, terms: [first, second]).text, "one Long")
        let low = term("First", ["same"], id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let high = term("Second", ["same"], id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        XCTAssertEqual(correctText("same", terms: [high, low]).text, "First")
        XCTAssertEqual(correctText("same", terms: [low, high]), correctText("same", terms: [high, low]))
    }

    func testFixedPointPromotesLongerCanonicalTermsAndMergesOriginalRanges() {
        let pro = term("ChatGPT Pro")
        let terms = [term("ChatGPT", ["chat GPT"]), pro]
        for input in ["chat GPT pro", "ChatGPT pro"] {
            let result = correctText(input, terms: terms)
            XCTAssertEqual(result.text, "ChatGPT Pro")
            XCTAssertTrue(result.converged)
            XCTAssertEqual(result.replacements.count, 1)
            XCTAssertEqual(result.replacements.first?.range, NSRange(location: 0, length: input.utf16.count))
            XCTAssertEqual(result.replacements.first?.original, input)
            XCTAssertEqual(result.replacements.first?.termID, pro.id)
            XCTAssertEqual(correctText(result.text, terms: terms).replacements, [])
        }
        let delta = term("Delta", ["Beta gamma"])
        let result = correctText("alpha gamma", terms: [term("Beta", ["alpha"]), delta])
        XCTAssertEqual(result.text, "Delta")
        XCTAssertEqual(result.replacements.first?.original, "alpha gamma")
        XCTAssertEqual(result.replacements.first?.replacement, "Delta")
        XCTAssertEqual(result.replacements.first?.termID, delta.id)
        XCTAssertTrue(result.converged)
        XCTAssertEqual(correctText(result.text, terms: [term("Beta", ["alpha"]), delta]).replacements, [])
    }

    func testChainsRemainSeparateWhenAdjacentAndMergeWhenGrowingBothWays() {
        let middle = term("Beta", ["alpha"])
        let final = term("Done", ["left Beta right"])
        let terms = [middle, final, term("Gamma", ["bravo"]), term("End", ["Gamma next"])]
        let input = "🙂 left alpha right bravo next!"
        let result = correctText(input, terms: terms)
        XCTAssertEqual(result.text, "🙂 Done End!")
        XCTAssertEqual(result.replacements.map(\.original), ["left alpha right", "bravo next"])
        XCTAssertEqual(result.replacements.map(\.replacement), ["Done", "End"])
        XCTAssertEqual(result.replacements.first?.range, (input as NSString).range(of: "left alpha right"))
        let joining = term("Together", ["Beta Gamma"])
        let joined = correctText("alpha bravo", terms: [middle, terms[2], joining])
        XCTAssertEqual(joined.replacements.count, 1)
        XCTAssertEqual(joined.replacements.first?.original, "alpha bravo")
        XCTAssertEqual(joined.replacements.first?.termID, joining.id)
    }

    func testPartialEarlierReplacementIsIncludedInMergedRange() {
        let result = correctText("a tail extra", terms: [term("left middle right", ["a"]), term("X", ["middle right tail extra"])])
        XCTAssertEqual(result.text, "left X")
        XCTAssertEqual(result.replacements.count, 1)
        XCTAssertEqual(result.replacements.first?.original, "a tail extra")
        XCTAssertEqual(result.replacements.first?.replacement, "left X")
    }

    func testNonconvergingGrowthStopsAtEightPasses() {
        let terms = [term("c a a", ["a"]), term("a a c b", ["a c c a"]),
            term("b c c c", ["c a a c"])]
        let result = correctText("c b a a", terms: terms)
        XCTAssertFalse(result.converged)
        XCTAssertEqual(result.text, "c b " + String(repeating: "b c c c ", count: 7) + "c a a c a a")
        XCTAssertEqual(result.replacements.count, 1)
        XCTAssertEqual(result.replacements.first?.original, "a a")
    }

    func testGrowthBudgetStopsBeforeAllocatingAnOversizedReplacement() {
        let input = String(repeating: "x ", count: 2_000)
        let result = correctText(input, terms: [term(String(repeating: "z", count: 1_024), ["x"])])
        XCTAssertEqual(result.text, input)
        XCTAssertEqual(result.replacements, [])
        XCTAssertFalse(result.converged)
    }

    func testCanonicalPunctuationCommonWordAliasesAndLongLiteral() {
        XCTAssertEqual(correctText("c++ .net A|B (X) \\D", terms: [term("C++"), term(".NET"), term("a|b"), term("(x)"), term(#"\d"#)]).text,
            #"C++ .NET a|b (x) \d"#)
        XCTAssertEqual(correctText("send it to Meg", terms: [term("Mac", ["Meg"])]).text, "send it to Mac")
        let long = String(repeating: "ž", count: 50_000)
        XCTAssertEqual(correctText(long.uppercased(), terms: [term(long)]).text, long)
    }

    func testCaseFoldingAndCombiningCharactersKeepWholeGraphemeRanges() {
        let input = "e\u{301} straße ßs a \u{301}b"
        let result = correctText(input, terms: [term("Café", ["é"]), term("Street", ["STRASSE"]),
            term("Letter", ["s"]), term("Pair", ["a b"])])
        XCTAssertEqual(result.text, "Café Street ßs a \u{301}b")
        XCTAssertEqual(result.replacements.first?.original, "e\u{301}")
        XCTAssertEqual(result.replacements.first?.range, NSRange(location: 0, length: 2))
        XCTAssertTrue(result.converged)
    }

    func testReplacementRangesReconstructOutputAcrossDeterministicAdversarialChains() {
        var state: UInt64 = 42
        func next(_ count: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 32) % UInt64(count))
        }
        func phrase() -> String {
            (0..<(1 + next(4))).map { _ in ["a", "b", "c"][next(3)] }.joined(separator: " ")
        }
        for _ in 0..<150 {
            let terms = (0..<3).map { _ in term(phrase(), [phrase()]) }
            let input = "👩🏽‍💻 e\u{301} " + phrase() + " " + phrase() + "!"
            let result = correctText(input, terms: terms)
            let rebuilt = NSMutableString(string: input)
            var end = 0
            for edit in result.replacements {
                XCTAssertGreaterThanOrEqual(edit.range.location, end)
                XCTAssertEqual((input as NSString).substring(with: edit.range), edit.original)
                end = NSMaxRange(edit.range)
            }
            for edit in result.replacements.reversed() { rebuilt.replaceCharacters(in: edit.range, with: edit.replacement) }
            XCTAssertEqual(Array((rebuilt as String).utf8), Array(result.text.utf8))
            if result.converged {
                let again = correctText(result.text, terms: terms)
                XCTAssertEqual(Array(again.text.utf8), Array(result.text.utf8))
                XCTAssertEqual(again.replacements, [])
            }
        }
    }

    func testHostileAndEmptyInputAndLiteralMetacharacters() {
        for input in ["", " \t\n", "no matching terms"] {
            let result = correctText(input, terms: [term("Valid", ["", "  "])])
            XCTAssertEqual(Array(result.text.utf8), Array(input.utf8))
            XCTAssertEqual(result.replacements, [])
            XCTAssertTrue(result.converged)
        }
        let aliases = ["C++", ".NET", "a|b", "(x)", #"\d"#, "!!!"]
        let terms = aliases.enumerated().map { term("Literal\($0.offset)", [$0.element]) }
        XCTAssertEqual(correctText(aliases.joined(separator: " "), terms: terms).text,
            "Literal0 Literal1 Literal2 Literal3 Literal4 Literal5")
        XCTAssertEqual(correctText("abc 123 axb", terms: terms).text, "abc 123 axb")
        XCTAssertEqual(correctText("!!!", terms: [term("!!!")]).replacements, [])
        XCTAssertEqual(correctText("x", terms: [term("", ["x"]), term("  ", ["x"])]).text, "x")
        var deleted = term("Wrong", ["x"])
        deleted.deletedAt = .now
        XCTAssertEqual(correctText("x", terms: [deleted]).text, "x")
        let long = String(repeating: "A realistic sentence stays exactly as dictated. 👋🏽\n", count: 10_000)
        XCTAssertEqual(Array(correctText(long, terms: terms).text.utf8), Array(long.utf8))
    }
}
