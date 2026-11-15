import Foundation
import VoiceAppCore
import XCTest

private struct NoteRandom {
    var state: UInt64 = 0x63a9b517
    mutating func next(_ limit: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int((state >> 32) % UInt64(limit))
    }
    mutating func choose<T>(_ values: [T]) -> T { values[next(values.count)] }
}

/// Generated notes use synthetic hits and an independent truth table for each grammar rule.
final class NoteDateGrammarPropertyTests: XCTestCase {
    func testDraftImpliesOpeningCueWholeShapeAndBothNeighbours() {
        let calendar = NoteTestSupport.calendar(NoteTestSupport.berlin)
        let reference = NoteTestSupport.date("2026-11-15 21:00", calendar.timeZone)
        let openings = [("remind me ", true), ("please remind me ", true), ("Other. remind me ", true),
                        ("I always remind me ", false), ("the note said remind me ", false), ("remind me why ", false)]
        let phrases = [("Friday", false, true), ("tomorrow", true, true), ("in 3 days", true, true),
                       ("November 25", false, true), ("24/7/2027", false, true),
                       ("next Friday", false, false), ("the first Monday", false, false),
                       ("9am", false, false), ("３/４/2027", false, false)]
        let before = [("", true, true), ("on ", true, true), ("to call on ", true, true),
                      ("call on ", false, false), ("to call ", true, false), ("a week ", false, false)]
        let after = [("", true), (".", true), (", thanks", true), (" to call", true),
                     (" da nazovem", true), (" week", false), (" the 27th", false), (" 30", false), (" za tjedan dana", false)]
        var random = NoteRandom()
        var accepted = 0
        for _ in 0..<6000 {
            let (cue, cueOK) = random.choose(openings)
            let (phrase, flexible, shapeOK) = random.choose(phrases)
            let (prefix, dayOK, fixedOK) = random.choose(before)
            let (suffix, afterOK) = random.choose(after)
            let text = cue + prefix + phrase + suffix
            let scanner = ScriptedDateScanner([.init(phrase: phrase, at: "2026-11-20 12:00")])
            let result = NoteDateParser(scanner: scanner).parse(text, reference: reference, calendar: calendar)
            let expected = cueOK && shapeOK && (flexible ? dayOK : fixedOK) && afterOK
            XCTAssertEqual(result.draft != nil, expected, text)
            if let draft = result.draft {
                accepted += 1
                XCTAssertTrue(cueOK && shapeOK && afterOK && (flexible ? dayOK : fixedOK), text)
                XCTAssertEqual(String(text[draft.matchedRange]), phrase)
            }
        }
        XCTAssertGreaterThan(accepted, 100)
    }
}

/// Real detector, real clock; process language overrides are test-only and restored by the base class.
final class NoteDateGrammarFuzzTests: ProcessSettingsTestCase {
    func testRandomUnicodeNotesCannotCrashOrBypassTheLengthCap() throws {
        let zone = NSTimeZone.default
        let calendar = NoteTestSupport.calendar(zone)
        let words = ["remind me", "remember to", "reminder:", "erinnere mich", "podsjeti me", "da", "to", "on", "tomorrow", "Friday", "sutra", "morgen", "November", "24/7/2027", "9:30", "９:３０", "٢٤/٧/٢٠٢٧", "९:३०", "０１２３４５６７８９", "٠١٢٣٤٥٦٧٨٩", "०१२३४५६७८९", ".", ":", ";", "\n", "?", "( )", "👩‍👩‍👧", "🎉"]
        var random = NoteRandom()
        let start = Date()
        try ProcessSettings.with(languages: ["en-US", "de-DE", "hr-HR"]) {
            for _ in 0..<3000 {
                var text = (0..<(random.next(18) + 1)).map { _ in random.choose(words) }.joined(separator: " ")
                if random.next(30) == 0 { text += String(repeating: "９", count: 4001) }
                let now = try NoteTestSupport.nowAwayFromMidnight(in: zone)
                let result = NoteDateParser().parse(text, reference: now, calendar: calendar)
                XCTAssertEqual(result.text, text)
                if text.utf16.count > NoteDateParser.maximumNoteLength { XCTAssertNil(result.draft) }
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 20, "bounded random inputs should finish promptly")
        let calls = Locked(0)
        struct CountingScanner: DateScanner {
            let calls: Locked<Int>
            func scan(_ text: String, reference: Date, timeZone: TimeZone) -> [ScannedDate] { calls.increment(); return [] }
        }
        let parser = NoteDateParser(scanner: CountingScanner(calls: calls))
        _ = parser.parse("remind me " + String(repeating: "9 ", count: 100_000), reference: Date(), calendar: calendar)
        XCTAssertEqual(calls.value, 0)
    }
}
