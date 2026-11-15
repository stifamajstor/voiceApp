import Foundation
import VoiceAppCore
import XCTest

/// The parser together with the real NSDataDetector. The detector reads the system clock, so each test starts from
/// the real "now" and derives its expectations from it. It also reads the process time zone and preferred
/// languages, which each parse switches to those of the user in the test (see SystemDateScannerTests).
final class NoteDateParserSystemTests: ProcessSettingsTestCase {
    private typealias Support = NoteTestSupport
    private let parser = NoteDateParser()

    /// Parses as a user in `zone` whose preferred language is `language` would.
    private func parse(_ text: String, at now: Date, in zone: TimeZone, language: String = "en_US") -> ParsedNote {
        ProcessSettings.asUser(in: zone, speaking: language) {
            parser.parse(text, reference: now, calendar: Support.calendar(zone))
        }
    }

    private func day(_ offset: Int, from now: Date, in zone: TimeZone, hour: Int? = nil, minute: Int? = nil) -> DateComponents {
        let calendar = Support.calendar(zone)
        let date = calendar.date(byAdding: .day, value: offset, to: now)!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return DateComponents(calendar: calendar, timeZone: zone, year: parts.year, month: parts.month, day: parts.day, hour: hour, minute: minute)
    }

    func testTomorrowAtNineInEachZone() throws {
        for zone in [Support.berlin, Support.losAngeles, Support.auckland] {
            let now = try Support.nowAwayFromMidnight(in: zone)
            let draft = parse("Call Anna tomorrow at 9", at: now, in: zone).draft
            XCTAssertEqual(draft?.kind, .reminder, zone.identifier)
            XCTAssertEqual(draft?.title, "Call Anna", zone.identifier)
            XCTAssertEqual(draft?.start, day(1, from: now, in: zone, hour: 9, minute: 0), zone.identifier)
            XCTAssertNil(draft?.end)
            XCTAssertEqual(draft?.matchedText, "tomorrow at 9")
        }
    }

    func testDatesWithoutATimeStayDates() throws {
        let zone = Support.berlin
        let now = try Support.nowAwayFromMidnight(in: zone)
        for (text, offset) in [("Buy milk tomorrow", 1), ("Buy milk today", 0), ("Buy milk in 3 days", 3), ("Buy milk the day after tomorrow", 2)] {
            XCTAssertEqual(parse(text, at: now, in: zone).draft?.start, day(offset, from: now, in: zone), text)
        }
    }

    func testTonightIsTodayWithoutATime() throws {
        let zone = Support.losAngeles
        let now = try Support.nowAwayFromMidnight(in: zone)
        XCTAssertEqual(parse("Gym tonight", at: now, in: zone).draft?.start, day(0, from: now, in: zone))
    }

    func testWeekdayIsTheRightWeekdayWithinTheNextWeek() throws {
        let zone = Support.berlin
        let now = try Support.nowAwayFromMidnight(in: zone)
        let calendar = Support.calendar(zone)
        let start = calendar.startOfDay(for: now)
        for (name, weekday) in [("Monday", 2), ("Wednesday", 4), ("Friday", 6), ("Sunday", 1)] {
            let draft = parse("Call Anna on \(name)", at: now, in: zone).draft
            let date = draft.flatMap { calendar.date(from: $0.start) }
            XCTAssertNotNil(date, name)
            guard let date else { continue }
            XCTAssertEqual(calendar.component(.weekday, from: date), weekday, name)
            let days = calendar.dateComponents([.day], from: start, to: date).day!
            XCTAssertTrue((0...7).contains(days), "\(name) is \(days) days away")
            XCTAssertNil(draft?.start.hour)
        }
    }

    func testTimeSpanBecomesAnEvent() throws {
        let zone = Support.berlin
        let now = try Support.nowAwayFromMidnight(in: zone)
        let draft = parse("Sync tomorrow from 3pm to 4:30pm", at: now, in: zone).draft
        XCTAssertEqual(draft?.kind, .event)
        XCTAssertEqual(draft?.title, "Sync")
        XCTAssertEqual(draft?.start, day(1, from: now, in: zone, hour: 15, minute: 0))
        XCTAssertEqual(draft?.end, day(1, from: now, in: zone, hour: 16, minute: 30))
    }

    func testMeetingWithATimeBecomesAnEventWithoutAnEnd() throws {
        let zone = Support.losAngeles
        let now = try Support.nowAwayFromMidnight(in: zone)
        let draft = parse("Meeting with Anna tomorrow at 3pm", at: now, in: zone).draft
        XCTAssertEqual(draft?.kind, .event)
        XCTAssertEqual(draft?.start, day(1, from: now, in: zone, hour: 15, minute: 0))
        XCTAssertNil(draft?.end)
    }

    func testDateWithAYearLaterThisYearOrNext() throws {
        let zone = Support.berlin
        let now = try Support.nowAwayFromMidnight(in: zone)
        let calendar = Support.calendar(zone)
        let target = calendar.date(byAdding: .day, value: 100, to: now)!
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "MMMM d, yyyy"
        let text = "Pay rent on \(formatter.string(from: target))"
        XCTAssertEqual(parse(text, at: now, in: zone).draft?.start, day(100, from: now, in: zone), text)
    }

    func testNothingFromADateTheDetectorGetsWrongOrDoesNotKnow() throws {
        let zone = Support.berlin
        let now = try Support.nowAwayFromMidnight(in: zone)
        let year = Support.calendar(zone).component(.year, from: now) + 1
        let notes = [
            // not dates
            "version 6.1", "version 2.5.1", "call 555 1234", "call 555-1234", "5%", "room 13", "it costs 5.99", "I need 5 apples",
            // times without a date
            "call Anna at 9am", "call Anna at 10:30", "at 9 o'clock", "sync from 3pm to 4pm", "at nine", "at ten thirty",
            // phrases the detector does not know
            "next week", "next month", "end of the month", "in two hours", "in 2 hours", "on the 13th", "the twenty-fifth", "noon",
            // in the past
            "yesterday", "last Friday", "2 days ago",
            // impossible or ambiguous
            "pay on February 30", "pay on November 31", "pay on 3/4/\(year)", "pay on 03.04.\(year)",
            // words the detector half understands
            "tomorrow at midnight",
        ]
        for text in notes {
            XCTAssertNil(parse(text, at: now, in: zone).draft, text)
        }
    }

    func testWordsForNumbersKeepOnlyTheDay() throws {
        let zone = Support.berlin
        let now = try Support.nowAwayFromMidnight(in: zone)
        for (text, title) in [("Call Anna tomorrow at nine", "Call Anna at nine"), ("Call Anna tomorrow at ten thirty", "Call Anna at ten thirty")] {
            let draft = parse(text, at: now, in: zone).draft
            XCTAssertEqual(draft?.start, day(1, from: now, in: zone), text)
            XCTAssertEqual(draft?.matchedText, "tomorrow", text)
            XCTAssertEqual(draft?.title, title, text)
        }
    }

    func testGermanAndCroatianKeepTheDayAndLoseTheClock() throws {
        let zone = Support.berlin
        let now = try Support.nowAwayFromMidnight(in: zone)
        let rows: [(text: String, language: String, matched: String?, offset: Int)] = [
            ("Anna anrufen morgen um 9", "de_DE", "morgen um 9", 1),
            ("Anna anrufen übermorgen", "de_DE", "übermorgen", 2),
            ("Anna anrufen in 3 Tagen", "de_DE", "in 3 Tagen", 3),
            ("nazvati Annu sutra u 9", "hr_HR", "sutra u 9", 1),
            ("nazvati Annu prekosutra", "hr_HR", "prekosutra", 2),
            ("nazvati Annu za 3 dana", "hr_HR", "za 3 dana", 3),
        ]
        for row in rows {
            let draft = parse(row.text, at: now, in: zone, language: row.language).draft
            XCTAssertEqual(draft?.matchedText, row.matched, row.text)
            XCTAssertEqual(draft?.start, day(row.offset, from: now, in: zone), row.text)
        }
        // Croatian with English as the language: the detector finds only a clock time, which is never enough.
        XCTAssertNil(parse("nazvati Annu sutra u 10:30", at: now, in: zone, language: "en_US").draft)
    }

    func testReferenceThatIsNotNowGivesNoDraft() throws {
        let zone = Support.berlin
        let now = try Support.nowAwayFromMidnight(in: zone)
        for offset: TimeInterval in [-86_400, -3_600, 3_600, 86_400 * 7] {
            XCTAssertNil(parse("Call Anna tomorrow at 9", at: now + offset, in: zone).draft, "\(offset)")
        }
    }

    func testCalendarInAnotherZoneThanTheSystemGivesNoDraft() throws {
        let now = try Support.nowAwayFromMidnight(in: Support.berlin)
        let draft = ProcessSettings.asUser(in: Support.berlin) {
            parser.parse("Call Anna tomorrow at 9", reference: now, calendar: Support.calendar(Support.losAngeles)).draft
        }
        XCTAssertNil(draft)
    }
}
