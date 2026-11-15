import Foundation
import VoiceAppCore
import XCTest

/// Synthetic scanner results isolate the non-grammar safety guards from NSDataDetector.
final class NoteDateParserRedesignTests: XCTestCase {
    private typealias Support = NoteTestSupport
    private typealias Hit = ScriptedDateScanner.Hit

    private func parse(_ text: String, hits: [Hit], now: String = "2026-11-15 21:00", zone: TimeZone = Support.berlin) -> ParsedNote {
        NoteDateParser(scanner: ScriptedDateScanner(hits))
            .parse(text, reference: Support.date(now, zone), calendar: Support.calendar(zone))
    }

    func testPastDatesAndTwoYearHorizon() {
        for at in ["2026-11-14 12:00", "2028-11-16 12:00"] {
            XCTAssertNil(parse("remind me on November 20", hits: [.init(phrase: "November 20", at: at)]).draft)
        }
        for (at, accepted) in [("2026-11-15 09:00", false), ("2026-11-15 21:00", false), ("2026-11-15 21:01", true)] {
            let phrase = "today at " + String(at.suffix(5))
            XCTAssertEqual(parse("remind me " + phrase, hits: [.init(phrase: phrase, at: at)]).draft != nil, accepted)
        }
        XCTAssertNotNil(parse("remind me today", hits: [.init(phrase: "today", at: "2026-11-15 12:00")]).draft)
        XCTAssertNotNil(parse("remind me on November 15 2028", hits: [.init(phrase: "November 15 2028", at: "2028-11-15 12:00")]).draft)
    }

    func testDifferentDatesAndUnsafeDuplicatesGiveNoDraft() {
        XCTAssertNil(parse("remind me tomorrow, Friday", hits: [
            .init(phrase: "tomorrow", at: "2026-11-16 12:00"), .init(phrase: "Friday", at: "2026-11-20 12:00")]).draft)
        XCTAssertNil(parse("remind me to call tomorrow, in 3 days", hits: [
            .init(phrase: "tomorrow", at: "2026-11-16 12:00"), .init(phrase: "in 3 days", at: "2026-11-18 12:00")]).draft)
        XCTAssertNil(parse("remind me tomorrow, 9am", hits: [
            .init(phrase: "tomorrow", at: "2026-11-16 12:00"), .init(phrase: "9am", at: "2026-11-16 12:00")]).draft)
        XCTAssertNotNil(parse("remind me tomorrow", hits: [
            .init(phrase: "tomorrow", at: "2026-11-16 12:00"), .init(phrase: "tomorrow", at: "2026-11-16 12:00")]).draft)
        XCTAssertNil(parse("remind me tomorrow", hits: [.init(phrase: "tomorrow", at: "2026-11-16 12:00", namesTimeZone: true)]).draft)
    }

    func testRolloversAndUnexplainedMidnightAreRefused() {
        for (phrase, at) in [("February 30", "2027-03-02 12:00"), ("February 29", "2027-03-01 12:00"), ("November 31", "2026-12-01 12:00")] {
            XCTAssertNil(parse("remind me on " + phrase, hits: [.init(phrase: phrase, at: at)]).draft)
        }
        XCTAssertNil(parse("remind me tomorrow", hits: [.init(phrase: "tomorrow", at: "2026-11-17 00:00")]).draft)
        XCTAssertNotNil(parse("remind me tomorrow at 0:30", hits: [.init(phrase: "tomorrow at 0:30", at: "2026-11-16 00:30")]).draft)
        XCTAssertNotNil(parse("remind me in 30 days", hits: [.init(phrase: "in 30 days", at: "2027-01-02 12:00")]).draft)
    }

    func testDigitClockMustExplainHourMinuteAndSeconds() {
        for (phrase, at, hour) in [
            ("tomorrow at 7", "2026-11-16 19:00", nil),
            ("tomorrow at 3", "2026-11-16 15:00", nil),
            ("tomorrow at 9", "2026-11-16 09:00", 9),
            ("tomorrow at 7pm", "2026-11-16 19:00", 19),
            ("tomorrow at 12am", "2026-11-16 00:00", 0),
            ("tomorrow at 12pm", "2026-11-16 12:00", 12),
            ("tomorrow at 9am", "2026-11-16 21:00", nil),
            ("tomorrow at 9:15", "2026-11-16 09:30", nil),
            ("tomorrow at 9:30", "2026-11-16 09:30:01", nil),
            ("November 13 at 1", "2026-11-20 13:00", nil),
            ("morgen um 9", "2026-11-16 09:00", nil),
            ("sutra u 9", "2026-11-16 09:00", nil),
        ] {
            let draft = parse("remind me on " + phrase, hits: [.init(phrase: phrase, at: at)]).draft
            XCTAssertNotNil(draft, phrase)
            XCTAssertEqual(draft?.start.hour, hour, phrase)
        }
    }

    func testDSTAndMidnightGuardsInBothZones() {
        for (zone, now, instants) in [
            (Support.berlin, "2027-03-27 23:59:30", ["2027-03-28 01:30", "2027-03-28 02:30"]),
            (Support.berlin, "2027-10-30 22:00", ["2027-10-31 00:30", "2027-10-31 01:30"]),
            (Support.losAngeles, "2027-03-13 23:50", ["2027-03-14 10:30"]),
            (Support.losAngeles, "2026-10-31 23:30", ["2026-11-01 08:30", "2026-11-01 09:30"]),
        ] {
            for instant in instants {
                let wall = Support.calendar(zone).dateComponents([.hour, .minute], from: Support.utc(instant))
                let phrase = "tomorrow at \(wall.hour!):30"
                let draft = parse("remind me " + phrase, hits: [.init(phrase: phrase, at: "", instant: Support.utc(instant))], now: now, zone: zone).draft
                XCTAssertNotNil(draft, instant)
                let near = zone.secondsFromGMT(for: Support.utc(instant) - 3600) != zone.secondsFromGMT(for: Support.utc(instant) + 3600)
                XCTAssertEqual(draft?.start.hour, near ? nil : wall.hour, instant)
            }
        }
        for zone in [Support.berlin, Support.losAngeles] {
            for now in ["2026-11-15 23:59:30", "2026-11-16 00:00:30"] {
                XCTAssertNotNil(parse("remind me tomorrow at 9", hits: [.init(phrase: "tomorrow at 9", at: "2026-11-16 09:00")], now: now, zone: zone).draft)
            }
            XCTAssertEqual(parse("remind me tonight", hits: [.init(phrase: "tonight", at: "2026-11-16 18:00")], now: "2026-11-16 00:00:30", zone: zone).draft?.start.day, 16)
        }
    }

    func testLengthCalendarAndScannerArguments() {
        let scanner = ScriptedDateScanner([.init(phrase: "tomorrow", at: "2026-11-16 12:00")])
        let parser = NoteDateParser(scanner: scanner)
        let reference = Support.date("2026-11-15 21:00", Support.berlin)
        let calendar = Support.calendar(Support.berlin)
        let limit = "remind me to " + String(repeating: "a", count: 3978) + " tomorrow"
        XCTAssertEqual(limit.utf16.count, 4000)
        XCTAssertNotNil(parser.parse(limit, reference: reference, calendar: calendar).draft)
        XCTAssertEqual(scanner.calls.count, 1)
        XCTAssertEqual(scanner.calls.first?.reference, reference)
        XCTAssertEqual(scanner.calls.first?.timeZone, calendar.timeZone)
        XCTAssertEqual(scanner.calls.first?.text, " to " + String(repeating: "a", count: 3978) + " tomorrow")
        for text in [limit + "x", "", " ", "call tomorrow", "remind me what tomorrow"] {
            XCTAssertNil(parser.parse(text, reference: reference, calendar: calendar).draft)
        }
        XCTAssertEqual(scanner.calls.count, 1)
        var other = Calendar(identifier: .buddhist)
        other.timeZone = calendar.timeZone
        XCTAssertNil(parser.parse("remind me tomorrow", reference: reference, calendar: other).draft)
        XCTAssertEqual(scanner.calls.count, 1)
    }
}
