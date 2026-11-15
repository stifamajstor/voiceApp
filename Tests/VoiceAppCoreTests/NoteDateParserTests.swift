import Foundation
import VoiceAppCore
import XCTest

/// Parser rules driven by synthetic scanner results, independent of NSDataDetector.
/// Every scripted hit in this class is synthetic, including the January 5, separated meeting/date,
/// report-due, lunch, dinner, afternoon and DST cases. They deliberately exercise one rule at a time;
/// they do not claim that the detector returns these ranges or instants. Live checks are in
/// NoteDateParserSystemTests and SystemDateScannerTests.
final class NoteDateParserTests: XCTestCase {
    private typealias Support = NoteTestSupport

    /// Returns synthetic hits; the zone passed to `scan` is the one `at` is read in.
    final class ScriptedScanner: DateScanner, @unchecked Sendable {
        struct Hit {
            var phrase: String
            var at: String
            var duration: TimeInterval = 0
            var namesTimeZone = false
            var instant: Date?
        }

        let hits: [Hit]
        private let lock = NSLock()
        private var seen: [(text: String, reference: Date, timeZone: TimeZone)] = []

        init(_ hits: [Hit]) { self.hits = hits }

        var calls: [(text: String, reference: Date, timeZone: TimeZone)] {
            lock.lock(); defer { lock.unlock() }
            return seen
        }

        func scan(_ text: String, reference: Date, timeZone: TimeZone) -> [ScannedDate] {
            lock.lock(); seen.append((text, reference, timeZone)); lock.unlock()
            return hits.compactMap { hit in
                guard let range = text.range(of: hit.phrase) else { return nil }
                return ScannedDate(
                    range: range, date: hit.instant ?? Support.date(hit.at, timeZone),
                    duration: hit.duration, namesTimeZone: hit.namesTimeZone)
            }
        }
    }

    struct Expected {
        var kind: NoteDraft.Kind = .reminder
        var title: String
        /// "2026-11-16" for a date, "2026-11-16 09:00" for a date with a time.
        var start: String
        var end: String?
        var matched: String
    }

    struct Case {
        var name: String
        var now: String
        var zone: TimeZone = Support.berlin
        var text: String
        var hits: [ScriptedScanner.Hit]
        var expected: Expected?
    }

    private static let sunday = "2026-11-15 21:00"

    private func components(_ text: String, _ zone: TimeZone) -> DateComponents {
        let calendar = Support.calendar(zone)
        let parts = text.split(separator: " ")
        let day = parts[0].split(separator: "-").map { Int($0)! }
        if parts.count == 1 {
            return DateComponents(calendar: calendar, timeZone: zone, year: day[0], month: day[1], day: day[2])
        }
        let time = parts[1].split(separator: ":").map { Int($0)! }
        return DateComponents(calendar: calendar, timeZone: zone, year: day[0], month: day[1], day: day[2], hour: time[0], minute: time[1])
    }

    private func run(_ cases: [Case], file: StaticString = #filePath, line: UInt = #line) {
        for c in cases {
            let parsed = NoteDateParser(scanner: ScriptedScanner(c.hits))
                .parse(c.text, reference: Support.date(c.now, c.zone), calendar: Support.calendar(c.zone))
            XCTAssertEqual(parsed.text, c.text, c.name, file: file, line: line)
            guard let expected = c.expected else {
                XCTAssertNil(parsed.draft, "\(c.name): expected no draft", file: file, line: line)
                continue
            }
            guard let draft = parsed.draft else {
                XCTFail("\(c.name): expected a draft", file: file, line: line)
                continue
            }
            XCTAssertEqual(draft.kind, expected.kind, c.name, file: file, line: line)
            XCTAssertEqual(draft.title, expected.title, c.name, file: file, line: line)
            XCTAssertEqual(draft.start, components(expected.start, c.zone), c.name, file: file, line: line)
            XCTAssertEqual(draft.end, expected.end.map { components($0, c.zone) }, c.name, file: file, line: line)
            XCTAssertEqual(draft.matchedText, expected.matched, c.name, file: file, line: line)
            XCTAssertEqual(String(c.text[draft.matchedRange]), expected.matched, c.name, file: file, line: line)
        }
    }

    private func hit(_ phrase: String, _ at: String, duration: TimeInterval = 0) -> ScriptedScanner.Hit {
        .init(phrase: phrase, at: at, duration: duration)
    }

    // MARK: A date is a reminder

    func testDatePhrasesBecomeReminders() {
        run([
            Case(name: "tomorrow with a digit time", now: Self.sunday, text: "Remind me to Call Anna tomorrow at 9",
                 hits: [hit("tomorrow at 9", "2026-11-16 09:00")],
                 expected: .init(title: "Call Anna", start: "2026-11-16 09:00", matched: "tomorrow at 9")),
            Case(name: "tomorrow alone keeps a date without a time", now: Self.sunday, text: "Remind me to Buy milk tomorrow",
                 hits: [hit("tomorrow", "2026-11-16 12:00")],
                 expected: .init(title: "Buy milk", start: "2026-11-16", matched: "tomorrow")),
            Case(name: "weekday", now: Self.sunday, text: "Remind me on Friday to call Anna",
                 hits: [hit("Friday", "2026-11-20 12:00")],
                 expected: .init(title: "call Anna", start: "2026-11-20", matched: "Friday")),
            Case(name: "weekday with a digit time", now: Self.sunday, text: "Remind me to Send the invoice Friday at 9",
                 hits: [hit("Friday at 9", "2026-11-20 09:00")],
                 expected: .init(title: "Send the invoice", start: "2026-11-20 09:00", matched: "Friday at 9")),
            Case(name: "next Friday is ambiguous", now: Self.sunday, text: "Remind me to Book flights next Friday",
                 hits: [hit("next Friday", "2026-11-20 12:00")],
                 expected: nil),
            Case(name: "in three days", now: Self.sunday, text: "Remind me to Water the plants in 3 days",
                 hits: [hit("in 3 days", "2026-11-18 12:00")],
                 expected: .init(title: "Water the plants", start: "2026-11-18", matched: "in 3 days")),
            Case(name: "month and day with a time", now: Self.sunday, text: "Remind me to Pay rent on November 20 at 10:30",
                 hits: [hit("November 20 at 10:30", "2026-11-20 10:30")],
                 expected: .init(title: "Pay rent", start: "2026-11-20 10:30", matched: "November 20 at 10:30")),
            Case(name: "month and day without a year, still ahead", now: "2026-10-01 09:00", text: "Remind me to Renew passport on Nov 13",
                 hits: [hit("Nov 13", "2026-11-13 12:00")],
                 expected: .init(title: "Renew passport", start: "2026-11-13", matched: "Nov 13")),
            Case(name: "date with a year", now: Self.sunday, text: "Remind me to File taxes on November 13, 2027",
                 hits: [hit("November 13, 2027", "2027-11-13 12:00")],
                 expected: .init(title: "File taxes", start: "2027-11-13", matched: "November 13, 2027")),
            Case(name: "ISO date", now: Self.sunday, text: "Remind me to Deadline 2027-03-04",
                 hits: [hit("2027-03-04", "2027-03-04 12:00")],
                 expected: .init(title: "Deadline", start: "2027-03-04", matched: "2027-03-04")),
            Case(name: "leap day in a leap year", now: "2027-11-15 09:00", text: "Remind me to Party on Feb 29 2028",
                 hits: [hit("Feb 29 2028", "2028-02-29 12:00")],
                 expected: .init(title: "Party", start: "2028-02-29", matched: "Feb 29 2028")),
            Case(name: "thirty days ahead landing on the 2nd is not a rollover", now: "2026-12-03 09:00", text: "Remind me to Check in 30 days",
                 hits: [hit("in 30 days", "2027-01-02 12:00")],
                 expected: .init(title: "Check", start: "2027-01-02", matched: "in 30 days")),
            Case(name: "today stays a date even late in the evening", now: Self.sunday, text: "Remind me to Buy milk today",
                 hits: [hit("today", "2026-11-15 12:00")],
                 expected: .init(title: "Buy milk", start: "2026-11-15", matched: "today")),
            Case(name: "later today", now: Self.sunday, text: "Remind me to Call Anna today at 22:00",
                 hits: [hit("today at 22:00", "2026-11-15 22:00")],
                 expected: .init(title: "Call Anna", start: "2026-11-15 22:00", matched: "today at 22:00")),
        ])
    }

    // MARK: Times are only kept when the digits in the note say so

    func testClockTimeIsKeptOnlyWhenItCanBeReadBackFromTheNote() {
        run([
            Case(name: "the detector moves a bare 7 to 19:00", now: Self.sunday, text: "Remind me to Gym tomorrow at 7",
                 hits: [hit("tomorrow at 7", "2026-11-16 19:00")],
                 expected: .init(title: "Gym", start: "2026-11-16", matched: "tomorrow at 7")),
            Case(name: "pm is explicit", now: Self.sunday, text: "Remind me to Gym tomorrow at 7pm",
                 hits: [hit("tomorrow at 7pm", "2026-11-16 19:00")],
                 expected: .init(title: "Gym", start: "2026-11-16 19:00", matched: "tomorrow at 7pm")),
            Case(name: "pm with a space and dots", now: Self.sunday, text: "Remind me to Gym tomorrow at 7 p.m.",
                 hits: [hit("tomorrow at 7 p.m.", "2026-11-16 19:00")],
                 expected: .init(title: "Gym", start: "2026-11-16 19:00", matched: "tomorrow at 7 p.m.")),
            Case(name: "24-hour clock", now: Self.sunday, text: "Remind me to Gym tomorrow at 19:00",
                 hits: [hit("tomorrow at 19:00", "2026-11-16 19:00")],
                 expected: .init(title: "Gym", start: "2026-11-16 19:00", matched: "tomorrow at 19:00")),
            Case(name: "a bare 3 moved to 15:00", now: Self.sunday, text: "Remind me to Dentist tomorrow at 3",
                 hits: [hit("tomorrow at 3", "2026-11-16 15:00")],
                 expected: .init(title: "Dentist", start: "2026-11-16", matched: "tomorrow at 3")),
            Case(name: "a bare 9 stays 9", now: Self.sunday, text: "Remind me to Dentist tomorrow at 9",
                 hits: [hit("tomorrow at 9", "2026-11-16 09:00")],
                 expected: .init(title: "Dentist", start: "2026-11-16 09:00", matched: "tomorrow at 9")),
            Case(name: "minutes must match", now: Self.sunday, text: "Remind me to Dentist tomorrow at 9:15",
                 hits: [hit("tomorrow at 9:15", "2026-11-16 09:30")],
                 expected: .init(title: "Dentist", start: "2026-11-16", matched: "tomorrow at 9:15")),
            Case(name: "the day number is not an hour", now: "2026-10-01 09:00", text: "Remind me to Dentist November 13 at 1",
                 hits: [hit("November 13 at 1", "2026-11-13 13:00")],
                 expected: .init(title: "Dentist", start: "2026-11-13", matched: "November 13 at 1")),
            Case(name: "explicit noon", now: Self.sunday, text: "Remind me to Lunch tomorrow at 12:00",
                 hits: [hit("tomorrow at 12:00", "2026-11-16 12:00")],
                 expected: .init(title: "Lunch", start: "2026-11-16 12:00", matched: "tomorrow at 12:00")),
            Case(name: "the word noon is not a digit time", now: Self.sunday, text: "Remind me to Lunch tomorrow at noon",
                 hits: [hit("tomorrow at noon", "2026-11-16 12:00")],
                 expected: .init(title: "Lunch", start: "2026-11-16", matched: "tomorrow at noon")),
            Case(name: "a part of the day is not a clock time", now: Self.sunday, text: "Remind me to Gym tomorrow morning",
                 hits: [hit("tomorrow morning", "2026-11-16 09:00")],
                 expected: .init(title: "Gym", start: "2026-11-16", matched: "tomorrow morning")),
            Case(name: "tonight is today without a time", now: Self.sunday, text: "Remind me to Gym tonight",
                 hits: [hit("tonight", "2026-11-15 18:00")],
                 expected: .init(title: "Gym", start: "2026-11-15", matched: "tonight")),
            Case(name: "midnight lands on the next day, so no draft", now: Self.sunday, text: "Remind me to Gym tomorrow at midnight",
                 hits: [hit("tomorrow at midnight", "2026-11-17 00:00")],
                 expected: nil),
            Case(name: "explicit 0:30", now: Self.sunday, text: "Remind me to Flight tomorrow at 0:30",
                 hits: [hit("tomorrow at 0:30", "2026-11-16 00:30")],
                 expected: .init(title: "Flight", start: "2026-11-16 00:30", matched: "tomorrow at 0:30")),
            Case(name: "words for the time are left to the day", now: Self.sunday, text: "Remind me to Call Anna Friday at nine",
                 hits: [hit("Friday", "2026-11-20 12:00")],
                 expected: .init(title: "Call Anna at nine", start: "2026-11-20", matched: "Friday")),
        ])
    }

    // MARK: Events need a trusted time span

    func testEventsNeedATrustedTimeSpan() {
        run([
            Case(name: "span with pm on both ends", now: Self.sunday, text: "Remind me to Sync tomorrow from 3pm to 4pm",
                 hits: [hit("tomorrow from 3pm to 4pm", "2026-11-16 15:00", duration: 3600)],
                 expected: .init(kind: .event, title: "Sync", start: "2026-11-16 15:00", end: "2026-11-16 16:00", matched: "tomorrow from 3pm to 4pm")),
            Case(name: "pm on the end covers the start", now: Self.sunday, text: "Remind me to Sync tomorrow from 3 to 4pm",
                 hits: [hit("tomorrow from 3 to 4pm", "2026-11-16 15:00", duration: 3600)],
                 expected: .init(kind: .event, title: "Sync", start: "2026-11-16 15:00", end: "2026-11-16 16:00", matched: "tomorrow from 3 to 4pm")),
            Case(name: "24-hour span", now: Self.sunday, text: "Remind me to Sync tomorrow from 15 to 16",
                 hits: [hit("tomorrow from 15 to 16", "2026-11-16 15:00", duration: 3600)],
                 expected: .init(kind: .event, title: "Sync", start: "2026-11-16 15:00", end: "2026-11-16 16:00", matched: "tomorrow from 15 to 16")),
            Case(name: "span with minutes", now: Self.sunday, text: "Remind me to Sync tomorrow from 9:30 to 10:15",
                 hits: [hit("tomorrow from 9:30 to 10:15", "2026-11-16 09:30", duration: 2700)],
                 expected: .init(kind: .event, title: "Sync", start: "2026-11-16 09:30", end: "2026-11-16 10:15", matched: "tomorrow from 9:30 to 10:15")),
            Case(name: "span across midnight", now: Self.sunday, text: "Remind me to Party tomorrow from 11pm to 1am",
                 hits: [hit("tomorrow from 11pm to 1am", "2026-11-16 23:00", duration: 7200)],
                 expected: .init(kind: .event, title: "Party", start: "2026-11-16 23:00", end: "2026-11-17 01:00", matched: "tomorrow from 11pm to 1am")),
            Case(name: "bare span the detector moved to the afternoon is only a reminder", now: Self.sunday, text: "Remind me to Sync tomorrow from 3 to 4",
                 hits: [hit("tomorrow from 3 to 4", "2026-11-16 15:00", duration: 3600)],
                 expected: .init(title: "Sync", start: "2026-11-16", matched: "tomorrow from 3 to 4")),
            Case(name: "end the detector moved to 17:00 drops the span but keeps a start that matches", now: Self.sunday, text: "Remind me to Workshop tomorrow from 9 to 5",
                 hits: [hit("tomorrow from 9 to 5", "2026-11-16 09:00", duration: 28800)],
                 expected: .init(title: "Workshop", start: "2026-11-16 09:00", matched: "tomorrow from 9 to 5")),
            Case(name: "a span of more than a day is not trusted, even when its end reads like the start", now: Self.sunday, text: "Remind me to Trip tomorrow from 9am to 9am",
                 hits: [hit("tomorrow from 9am to 9am", "2026-11-16 09:00", duration: 172_800)],
                 expected: .init(title: "Trip", start: "2026-11-16 09:00", matched: "tomorrow from 9am to 9am")),
            Case(name: "a span with no clock time is a misread offset, not a date", now: Self.sunday, text: "Remind me to A week from Friday",
                 hits: [hit("from Friday", "2026-11-20 12:00", duration: 3600)], expected: nil),
            Case(name: "two weeks from tomorrow", now: Self.sunday, text: "Remind me to Call Anna two weeks from tomorrow",
                 hits: [hit("from tomorrow", "2026-11-16 12:00", duration: 3600)], expected: nil),
            Case(name: "meeting with a time", now: Self.sunday, text: "Remind me to Meeting with Anna tomorrow at 3pm",
                 hits: [hit("tomorrow at 3pm", "2026-11-16 15:00")],
                 expected: .init(title: "Meeting with Anna", start: "2026-11-16 15:00", matched: "tomorrow at 3pm")),
            Case(name: "appointment with a time", now: Self.sunday, text: "Remind me to Dentist appointment on November 20 at 9:30",
                 hits: [hit("November 20 at 9:30", "2026-11-20 09:30")],
                 expected: .init(title: "Dentist appointment", start: "2026-11-20 09:30", matched: "November 20 at 9:30")),
            Case(name: "call with someone, with a time", now: Self.sunday, text: "Remind me to Call with Anna tomorrow at 6pm",
                 hits: [hit("tomorrow at 6pm", "2026-11-16 18:00")],
                 expected: .init(title: "Call with Anna", start: "2026-11-16 18:00", matched: "tomorrow at 6pm")),
            Case(name: "meeting is a keyword in any case", now: Self.sunday, text: "Remind me to TEAM MEETING Friday at 2pm",
                 hits: [hit("Friday at 2pm", "2026-11-20 14:00")],
                 expected: .init(title: "TEAM MEETING", start: "2026-11-20 14:00", matched: "Friday at 2pm")),
            Case(name: "calling someone is a to-do, not an event", now: Self.sunday, text: "Remind me to Call mom tomorrow at 6pm",
                 hits: [hit("tomorrow at 6pm", "2026-11-16 18:00")],
                 expected: .init(title: "Call mom", start: "2026-11-16 18:00", matched: "tomorrow at 6pm")),
            Case(name: "a meeting without a time is a reminder", now: Self.sunday, text: "Remind me to Meeting with Anna tomorrow",
                 hits: [hit("tomorrow", "2026-11-16 12:00")],
                 expected: .init(title: "Meeting with Anna", start: "2026-11-16", matched: "tomorrow")),
            Case(name: "a meeting whose time cannot be trusted is a reminder", now: Self.sunday, text: "Remind me to Meeting tomorrow at 7",
                 hits: [hit("tomorrow at 7", "2026-11-16 19:00")],
                 expected: .init(title: "Meeting", start: "2026-11-16", matched: "tomorrow at 7")),
            Case(name: "plural keyword", now: Self.sunday, text: "Remind me to Meetings notes tomorrow at 9",
                 hits: [hit("tomorrow at 9", "2026-11-16 09:00")],
                 expected: .init(title: "Meetings notes", start: "2026-11-16 09:00", matched: "tomorrow at 9")),
            Case(name: "word that merely contains the keyword", now: Self.sunday, text: "Remind me to Recall the appointmentsheet tomorrow at 9",
                 hits: [hit("tomorrow at 9", "2026-11-16 09:00")],
                 expected: .init(title: "Recall the appointmentsheet", start: "2026-11-16 09:00", matched: "tomorrow at 9")),
        ])
    }

    // MARK: No draft

    func testNoDraftWhenNoDateIsFound() {
        run([
            Case(name: "plain note", now: Self.sunday, text: "Remind me to Buy milk", hits: [], expected: nil),
            Case(name: "empty", now: Self.sunday, text: "", hits: [], expected: nil),
            Case(name: "whitespace only", now: Self.sunday, text: "  \n\t  ", hits: [hit("tomorrow", "2026-11-16 12:00")], expected: nil),
            Case(name: "next week is not known to the detector", now: Self.sunday, text: "Remind me to Plan the sprint next week", hits: [], expected: nil),
            Case(name: "end of the month is not known to the detector", now: Self.sunday, text: "Remind me to Pay rent at the end of the month", hits: [], expected: nil),
            Case(name: "in two hours is not known to the detector", now: Self.sunday, text: "Remind me to Call Anna in two hours", hits: [], expected: nil),
            Case(name: "the 13th alone is not known to the detector", now: Self.sunday, text: "Remind me to Pay rent on the 13th", hits: [], expected: nil),
        ])
    }

    func testNoDraftForATimeWithoutADay() {
        run([
            Case(name: "9am", now: Self.sunday, text: "Remind me to Call Anna at 9am", hits: [hit("9am", "2026-11-16 09:00")], expected: nil),
            Case(name: "10:30", now: Self.sunday, text: "Remind me to Call Anna at 10:30", hits: [hit("10:30", "2026-11-15 22:30")], expected: nil),
            Case(name: "o'clock", now: Self.sunday, text: "Remind me to Call Anna at 9 o'clock", hits: [hit("9 o'clock", "2026-11-16 09:00")], expected: nil),
            Case(name: "dotted time", now: Self.sunday, text: "Remind me to Call Anna at 9.30", hits: [hit("9.30", "2026-11-16 09:30")], expected: nil),
            Case(name: "span without a day", now: Self.sunday, text: "Remind me to Sync from 3pm to 4pm", hits: [hit("from 3pm to 4pm", "2026-11-16 15:00", duration: 3600)], expected: nil),
            Case(name: "dashed span without a day", now: Self.sunday, text: "Remind me to Sync 3-4pm", hits: [hit("3-4pm", "2026-11-16 15:00", duration: 3600)], expected: nil),
            Case(name: "German time without a day", now: Self.sunday, text: "Remind me to um 9 Uhr anrufen", hits: [hit("9 Uhr", "2026-11-16 09:00")], expected: nil),
            Case(name: "Croatian clock time the detector finds without a day", now: Self.sunday, text: "Remind me to sutra u 10:30",
                 hits: [hit("10:30", "2026-11-15 22:30")], expected: nil),
            Case(name: "a dotted date is not a time", now: "2026-10-01 09:00", text: "Remind me to Pay 13.11.2026",
                 hits: [hit("13.11.2026", "2026-11-13 12:00")],
                 expected: .init(title: "Pay", start: "2026-11-13", matched: "13.11.2026")),
        ])
    }

    func testNoDraftForADateInThePast() {
        run([
            Case(name: "earlier this month", now: Self.sunday, text: "Remind me to Call Anna on November 13", hits: [hit("November 13", "2026-11-13 12:00")], expected: nil),
            Case(name: "yesterday", now: Self.sunday, text: "Remind me to Call Anna yesterday", hits: [hit("yesterday", "2026-11-14 12:00")], expected: nil),
            Case(name: "last Friday", now: Self.sunday, text: "Remind me to Met Anna last Friday", hits: [hit("last Friday", "2026-11-06 12:00")], expected: nil),
            Case(name: "earlier today", now: Self.sunday, text: "Remind me to Call Anna today at 9", hits: [hit("today at 9", "2026-11-15 09:00")], expected: nil),
            Case(name: "exactly now", now: Self.sunday, text: "Remind me to Call Anna today at 21:00", hits: [hit("today at 21:00", "2026-11-15 21:00")], expected: nil),
            Case(name: "one minute ahead", now: Self.sunday, text: "Remind me to Call Anna today at 21:01", hits: [hit("today at 21:01", "2026-11-15 21:01")],
                 expected: .init(title: "Call Anna", start: "2026-11-15 21:01", matched: "today at 21:01")),
            Case(name: "a year ago", now: Self.sunday, text: "Remind me to Born on November 13, 2025", hits: [hit("November 13, 2025", "2025-11-13 12:00")], expected: nil),
        ])
    }

    func testNoDraftForADateMoreThanTwoYearsAway() {
        run([
            Case(name: "on the limit", now: Self.sunday, text: "Remind me to Party on Nov 15 2028", hits: [hit("Nov 15 2028", "2028-11-15 12:00")],
                 expected: .init(title: "Party", start: "2028-11-15", matched: "Nov 15 2028")),
            Case(name: "a day past the limit", now: Self.sunday, text: "Remind me to Party on Nov 16 2028", hits: [hit("Nov 16 2028", "2028-11-16 12:00")], expected: nil),
            Case(name: "far away", now: Self.sunday, text: "Remind me to Party on November 13, 2030", hits: [hit("November 13, 2030", "2030-11-13 12:00")], expected: nil),
        ])
    }

    func testNoDraftWhenSeveralDifferentDatesAreFound() {
        run([
            Case(name: "two days with times", now: Self.sunday, text: "Remind me to Monday at 9 and Tuesday at 10",
                 hits: [hit("Monday at 9", "2026-11-16 09:00"), hit("Tuesday at 10", "2026-11-17 10:00")], expected: nil),
            Case(name: "either of two days", now: Self.sunday, text: "Remind me to Friday or Saturday",
                 hits: [hit("Friday", "2026-11-20 12:00"), hit("Saturday", "2026-11-21 12:00")], expected: nil),
            Case(name: "a day and a time apart from it", now: Self.sunday, text: "Remind me to Meeting Friday, starts at 9am",
                 hits: [hit("Friday", "2026-11-20 12:00"), hit("9am", "2026-11-16 09:00")], expected: nil),
            Case(name: "tomorrow and the day after", now: Self.sunday, text: "Remind me to tomorrow and the day after tomorrow",
                 hits: [hit("tomorrow", "2026-11-16 12:00"), hit("the day after tomorrow", "2026-11-17 12:00")], expected: nil),
            Case(name: "the same day twice is one date", now: Self.sunday, text: "Remind me to Tomorrow I will do it tomorrow",
                 hits: [hit("Tomorrow", "2026-11-16 12:00"), hit("tomorrow", "2026-11-16 12:00")],
                 expected: .init(title: "I will do it tomorrow", start: "2026-11-16", matched: "Tomorrow")),
        ])
    }

    func testNoDraftWhenTheDetectorRolledAnImpossibleDateForward() {
        run([
            Case(name: "February 30", now: "2027-01-10 12:00", text: "Remind me to Pay on February 30", hits: [hit("February 30", "2027-03-02 12:00")], expected: nil),
            Case(name: "February 29 in a common year", now: Self.sunday, text: "Remind me to Party on Feb 29 2027", hits: [hit("Feb 29 2027", "2027-03-01 12:00")], expected: nil),
            Case(name: "November 31", now: Self.sunday, text: "Remind me to Pay on November 31", hits: [hit("November 31", "2026-12-01 12:00")], expected: nil),
            Case(name: "April 31", now: "2027-03-10 12:00", text: "Remind me to Pay on 31 April", hits: [hit("31 April", "2027-05-01 12:00")], expected: nil),
            Case(name: "numeric 02/30/2027", now: "2027-01-10 12:00", text: "Remind me to Pay on 02/30/2027", hits: [hit("02/30/2027", "2027-03-02 12:00")], expected: nil),
            Case(name: "the 31st of a month that has one", now: Self.sunday, text: "Remind me to Pay on December 31", hits: [hit("December 31", "2026-12-31 12:00")],
                 expected: .init(title: "Pay", start: "2026-12-31", matched: "December 31")),
        ])
    }

    func testNoDraftForNumericDatesWhoseDayAndMonthCouldBeSwapped() {
        run([
            Case(name: "3/4/2027", now: Self.sunday, text: "Remind me to Pay on 3/4/2027", hits: [hit("3/4/2027", "2027-03-04 12:00")], expected: nil),
            Case(name: "03.04.2027", now: Self.sunday, text: "Remind me to Pay on 03.04.2027", hits: [hit("03.04.2027", "2027-04-03 12:00")], expected: nil),
            Case(name: "3-4-2027", now: Self.sunday, text: "Remind me to Pay on 3-4-2027", hits: [hit("3-4-2027", "2027-03-04 12:00")], expected: nil),
            Case(name: "3/4/27", now: Self.sunday, text: "Remind me to Pay on 3/4/27", hits: [hit("3/4/27", "2027-03-04 12:00")], expected: nil),
            Case(name: "4/5 with no year", now: Self.sunday, text: "Remind me to Pay on 4/5", hits: [hit("4/5", "2027-04-05 12:00")], expected: nil),
            Case(name: "13/3/2027 can only be day first", now: Self.sunday, text: "Remind me to Pay on 13/3/2027", hits: [hit("13/3/2027", "2027-03-13 12:00")],
                 expected: .init(title: "Pay", start: "2027-03-13", matched: "13/3/2027")),
            Case(name: "3/13/2027 can only be month first", now: Self.sunday, text: "Remind me to Pay on 3/13/2027", hits: [hit("3/13/2027", "2027-03-13 12:00")],
                 expected: .init(title: "Pay", start: "2027-03-13", matched: "3/13/2027")),
            Case(name: "3/3/2027 reads the same both ways", now: Self.sunday, text: "Remind me to Pay on 3/3/2027", hits: [hit("3/3/2027", "2027-03-03 12:00")],
                 expected: .init(title: "Pay", start: "2027-03-03", matched: "3/3/2027")),
            Case(name: "11/13 with no year", now: "2026-10-01 09:00", text: "Remind me to Pay on 11/13", hits: [hit("11/13", "2026-11-13 12:00")],
                 expected: nil),
            Case(name: "a dashed span after a day is not a date", now: Self.sunday, text: "Remind me to Sync tomorrow 3-4pm",
                 hits: [hit("tomorrow 3-4pm", "2026-11-16 15:00", duration: 3600)],
                 expected: .init(title: "Sync", start: "2026-11-16", matched: "tomorrow 3-4pm")),
        ])
    }

    func testNoDraftWhenThePhraseNamesItsOwnTimeZone() {
        run([
            Case(name: "9am PST", now: Self.sunday, text: "Remind me to Call Anna tomorrow at 9am PST",
                 hits: [.init(phrase: "tomorrow at 9am PST", at: "2026-11-16 18:00", namesTimeZone: true)], expected: nil),
        ])
    }

    func testNoDraftForAnUnsupportedCalendar() {
        let reference = Support.date(Self.sunday, Support.berlin)
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = Support.berlin
        let parsed = NoteDateParser(scanner: ScriptedScanner([hit("tomorrow", "2026-11-16 12:00")]))
            .parse("Remind me to Buy milk tomorrow", reference: reference, calendar: buddhist)
        XCTAssertNil(parsed.draft)
    }

    // MARK: Hostile input

    func testVeryLongNotesAreNotScanned() {
        let scanner = ScriptedScanner([hit("tomorrow", "2026-11-16 12:00")])
        let parser = NoteDateParser(scanner: scanner)
        let reference = Support.date(Self.sunday, Support.berlin)
        let calendar = Support.calendar(Support.berlin)

        let tooLong = "reminder " + String(repeating: "a", count: NoteDateParser.maximumNoteLength - 17) + " tomorrow"
        XCTAssertNil(parser.parse(tooLong, reference: reference, calendar: calendar).draft)
        XCTAssertEqual(scanner.calls.count, 0)

        let atTheLimit = "reminder " + String(repeating: "a", count: NoteDateParser.maximumNoteLength - 18) + " tomorrow"
        XCTAssertEqual(atTheLimit.utf16.count, NoteDateParser.maximumNoteLength)
        let draft = parser.parse(atTheLimit, reference: reference, calendar: calendar).draft
        XCTAssertNotNil(draft)
        XCTAssertEqual(scanner.calls.count, 1)
    }

    func testBlankNotesAreNotScanned() {
        let scanner = ScriptedScanner([hit("tomorrow", "2026-11-16 12:00")])
        let parser = NoteDateParser(scanner: scanner)
        for text in ["", " ", "\n\n", " \t\n "] {
            XCTAssertNil(parser.parse(text, reference: Support.date(Self.sunday, Support.berlin), calendar: Support.calendar(Support.berlin)).draft)
        }
        XCTAssertEqual(scanner.calls.count, 0)
    }

    func testScannerGetsTheCallersReferenceAndZone() {
        let scanner = ScriptedScanner([])
        let reference = Support.date(Self.sunday, Support.losAngeles)
        _ = NoteDateParser(scanner: scanner)
            .parse("Remind me to Buy milk tomorrow", reference: reference, calendar: Support.calendar(Support.losAngeles))
        XCTAssertEqual(scanner.calls.count, 1)
        XCTAssertEqual(scanner.calls.first?.text, "Remind me to Buy milk tomorrow")
        XCTAssertEqual(scanner.calls.first?.reference, reference)
        XCTAssertEqual(scanner.calls.first?.timeZone, Support.losAngeles)
    }

    // MARK: Titles

    func testTitleIsTheNoteWithoutTheDatePhrase() {
        let sixtyWords = String(repeating: "word ", count: 30) + "tomorrow"
        let nineteenWords = String(repeating: "word ", count: 19).trimmingCharacters(in: .whitespaces) + "…"
        let oneHugeWord = String(repeating: "x", count: 200)
        let exactlyOneHundred = String(repeating: "y", count: 100)
        run([
            Case(name: "preposition in front of the phrase goes with it", now: Self.sunday, text: "Remind me to meeting with Anna on Friday at 2pm",
                 hits: [hit("Friday at 2pm", "2026-11-20 14:00")],
                 expected: .init(title: "meeting with Anna", start: "2026-11-20 14:00", matched: "Friday at 2pm")),
            Case(name: "by", now: Self.sunday, text: "Remind me to Submit report by Friday", hits: [hit("Friday", "2026-11-20 12:00")],
                 expected: .init(title: "Submit report", start: "2026-11-20", matched: "Friday")),
            Case(name: "due", now: Self.sunday, text: "Remind me to Report due Friday", hits: [hit("Friday", "2026-11-20 12:00")],
                 expected: .init(title: "Report", start: "2026-11-20", matched: "Friday")),
            Case(name: "only one preposition goes", now: Self.sunday, text: "Remind me to Call Anna for the party on Friday", hits: [hit("Friday", "2026-11-20 12:00")],
                 expected: .init(title: "Call Anna for the party", start: "2026-11-20", matched: "Friday")),
            Case(name: "punctuation around the phrase", now: Self.sunday, text: "Remind me to Buy milk, tomorrow.", hits: [hit("tomorrow", "2026-11-16 12:00")],
                 expected: .init(title: "Buy milk", start: "2026-11-16", matched: "tomorrow")),
            Case(name: "line breaks collapse", now: Self.sunday, text: "Remind me to Buy milk\n\ntomorrow\nand eggs", hits: [hit("tomorrow", "2026-11-16 12:00")],
                 expected: .init(title: "Buy milk and eggs", start: "2026-11-16", matched: "tomorrow")),
            Case(name: "phrase in the middle", now: Self.sunday, text: "Remind me to Tell Anna tomorrow that the printer is broken", hits: [hit("tomorrow", "2026-11-16 12:00")],
                 expected: .init(title: "Tell Anna that the printer is broken", start: "2026-11-16", matched: "tomorrow")),
            Case(name: "remind me to", now: Self.sunday, text: "Please remind me to call Anna tomorrow", hits: [hit("tomorrow", "2026-11-16 12:00")],
                 expected: .init(title: "call Anna", start: "2026-11-16", matched: "tomorrow")),
            Case(name: "remind me about", now: Self.sunday, text: "Remind me about the rent on Friday", hits: [hit("Friday", "2026-11-20 12:00")],
                 expected: .init(title: "the rent", start: "2026-11-20", matched: "Friday")),
            Case(name: "nothing left after the request is dropped: the note itself", now: Self.sunday, text: "Remind me tomorrow",
                 hits: [hit("tomorrow", "2026-11-16 12:00")],
                 expected: .init(title: "Remind me tomorrow", start: "2026-11-16", matched: "tomorrow")),
            Case(name: "only a date: the note itself", now: Self.sunday, text: "Remind me to tomorrow", hits: [hit("tomorrow", "2026-11-16 12:00")],
                 expected: .init(title: "Remind me to tomorrow", start: "2026-11-16", matched: "tomorrow")),
            Case(name: "only a date with spaces and a full stop", now: Self.sunday, text: "Remind me to   Tomorrow at 9. ", hits: [hit("Tomorrow at 9", "2026-11-16 09:00")],
                 expected: .init(title: "Remind me to Tomorrow at 9", start: "2026-11-16 09:00", matched: "Tomorrow at 9")),
            Case(name: "long note is cut at a word", now: Self.sunday, text: "Remind me to " + sixtyWords, hits: [hit("tomorrow", "2026-11-16 12:00")],
                 expected: .init(title: nineteenWords, start: "2026-11-16", matched: "tomorrow")),
            Case(name: "long word is cut at the limit", now: Self.sunday, text: "Remind me to " + oneHugeWord + " tomorrow", hits: [hit("tomorrow", "2026-11-16 12:00")],
                 expected: .init(title: String(repeating: "x", count: 99) + "…", start: "2026-11-16", matched: "tomorrow")),
            Case(name: "a title of exactly the limit is kept", now: Self.sunday, text: "Remind me to " + exactlyOneHundred + " tomorrow", hits: [hit("tomorrow", "2026-11-16 12:00")],
                 expected: .init(title: exactlyOneHundred, start: "2026-11-16", matched: "tomorrow")),
            Case(name: "emoji around the phrase", now: Self.sunday, text: "Remind me to 👩‍👩‍👧 Call Anna tomorrow at 9 🎉", hits: [hit("tomorrow at 9", "2026-11-16 09:00")],
                 expected: .init(title: "👩‍👩‍👧 Call Anna 🎉", start: "2026-11-16 09:00", matched: "tomorrow at 9")),
            Case(name: "accents", now: Self.sunday, text: "Remind me to Zürich anrufen am Freitag", hits: [hit("Freitag", "2026-11-20 12:00")],
                 expected: .init(title: "Zürich anrufen", start: "2026-11-20", matched: "Freitag")),
        ])
    }

    // MARK: Daylight saving, midnight and time zones

    func testWallTimesNearADaylightSavingChangeAreNotTrusted() {
        func at(_ phrase: String, _ instant: String) -> ScriptedScanner.Hit {
            .init(phrase: phrase, at: "", instant: Support.utc(instant))
        }
        run([
            // Berlin springs forward on 2027-03-28: 02:00 CET becomes 03:00 CEST at 01:00 UTC.
            Case(name: "Berlin: synthetic nonexistent 2:30 resolved to 3:30", now: "2027-03-27 23:59:30", text: "Remind me to Call Anna tomorrow at 2:30",
                 hits: [at("tomorrow at 2:30", "2027-03-28 01:30")],
                 expected: .init(title: "Call Anna", start: "2027-03-28", matched: "tomorrow at 2:30")),
            Case(name: "Berlin: 3:30 CEST is within an hour of the change", now: "2027-03-27 23:59:30", text: "Remind me to Call Anna tomorrow at 3:30",
                 hits: [at("tomorrow at 3:30", "2027-03-28 01:30")],
                 expected: .init(title: "Call Anna", start: "2027-03-28", matched: "tomorrow at 3:30")),
            Case(name: "Berlin: 4:00 CEST is clear of it", now: "2027-03-27 23:59:30", text: "Remind me to Call Anna tomorrow at 4:00",
                 hits: [at("tomorrow at 4:00", "2027-03-28 02:00")],
                 expected: .init(title: "Call Anna", start: "2027-03-28 04:00", matched: "tomorrow at 4:00")),
            Case(name: "Berlin: 9:00 on the day", now: "2027-03-27 23:59:30", text: "Remind me to Call Anna tomorrow at 9",
                 hits: [at("tomorrow at 9", "2027-03-28 07:00")],
                 expected: .init(title: "Call Anna", start: "2027-03-28 09:00", matched: "tomorrow at 9")),
            Case(name: "Berlin: a span that starts at the change is only a reminder", now: "2027-03-27 23:59:30", text: "Remind me to Call with Anna tomorrow from 1am to 4am",
                 hits: [.init(phrase: "tomorrow from 1am to 4am", at: "", duration: 7200, instant: Support.utc("2027-03-28 00:00"))],
                 expected: .init(title: "Call with Anna", start: "2027-03-28", matched: "tomorrow from 1am to 4am")),
            // Berlin falls back on 2027-10-31: 03:00 CEST becomes 02:00 CET at 01:00 UTC, so 2:30 happens twice.
            Case(name: "Berlin: first 2:30", now: "2027-10-30 22:00", text: "Remind me to Call Anna tomorrow at 2:30",
                 hits: [at("tomorrow at 2:30", "2027-10-31 00:30")],
                 expected: .init(title: "Call Anna", start: "2027-10-31", matched: "tomorrow at 2:30")),
            Case(name: "Berlin: second 2:30", now: "2027-10-30 22:00", text: "Remind me to Call Anna tomorrow at 2:30",
                 hits: [at("tomorrow at 2:30", "2027-10-31 01:30")],
                 expected: .init(title: "Call Anna", start: "2027-10-31", matched: "tomorrow at 2:30")),
            Case(name: "Berlin: 9:00 on the fall-back day", now: "2027-10-30 22:00", text: "Remind me to Call Anna tomorrow at 9",
                 hits: [at("tomorrow at 9", "2027-10-31 08:00")],
                 expected: .init(title: "Call Anna", start: "2027-10-31 09:00", matched: "tomorrow at 9")),
            // Los Angeles springs forward on 2027-03-14: 02:00 PST becomes 03:00 PDT at 10:00 UTC.
            Case(name: "Los Angeles: 2:30 does not exist", now: "2027-03-13 23:50", zone: Support.losAngeles, text: "Remind me to Call Anna tomorrow at 2:30",
                 hits: [at("tomorrow at 2:30", "2027-03-14 10:30")],
                 expected: .init(title: "Call Anna", start: "2027-03-14", matched: "tomorrow at 2:30")),
            Case(name: "Los Angeles: 9am on the day", now: "2027-03-13 23:50", zone: Support.losAngeles, text: "Remind me to Call Anna tomorrow at 9am",
                 hits: [at("tomorrow at 9am", "2027-03-14 16:00")],
                 expected: .init(title: "Call Anna", start: "2027-03-14 09:00", matched: "tomorrow at 9am")),
            // Los Angeles falls back on 2026-11-01: 02:00 PDT becomes 01:00 PST at 09:00 UTC, so 1:30 happens twice.
            Case(name: "Los Angeles: first 1:30", now: "2026-10-31 23:30", zone: Support.losAngeles, text: "Remind me to Call Anna tomorrow at 1:30",
                 hits: [at("tomorrow at 1:30", "2026-11-01 08:30")],
                 expected: .init(title: "Call Anna", start: "2026-11-01", matched: "tomorrow at 1:30")),
            Case(name: "Los Angeles: second 1:30", now: "2026-10-31 23:30", zone: Support.losAngeles, text: "Remind me to Call Anna tomorrow at 1:30",
                 hits: [at("tomorrow at 1:30", "2026-11-01 09:30")],
                 expected: .init(title: "Call Anna", start: "2026-11-01", matched: "tomorrow at 1:30")),
        ])
    }

    func testReferenceJustBeforeOrAfterMidnight() {
        for zone in [Support.berlin, Support.losAngeles] {
            let id = zone.identifier
            run([
                Case(name: "\(id): tomorrow at 9 from 23:59:30", now: "2026-11-15 23:59:30", zone: zone, text: "Remind me to Call Anna tomorrow at 9",
                     hits: [hit("tomorrow at 9", "2026-11-16 09:00")],
                     expected: .init(title: "Call Anna", start: "2026-11-16 09:00", matched: "tomorrow at 9")),
                Case(name: "\(id): today is still today", now: "2026-11-15 23:59:30", zone: zone, text: "Remind me to Buy milk today",
                     hits: [hit("today", "2026-11-15 12:00")],
                     expected: .init(title: "Buy milk", start: "2026-11-15", matched: "today")),
                Case(name: "\(id): 23:59 has already gone", now: "2026-11-15 23:59:30", zone: zone, text: "Remind me to Call Anna today at 11:59pm",
                     hits: [hit("today at 11:59pm", "2026-11-15 23:59")], expected: nil),
                Case(name: "\(id): just after midnight tonight is the new day", now: "2026-11-16 00:00:30", zone: zone, text: "Remind me to Gym tonight",
                     hits: [hit("tonight", "2026-11-16 18:00")],
                     expected: .init(title: "Gym", start: "2026-11-16", matched: "tonight")),
                Case(name: "\(id): just after midnight yesterday is the old day", now: "2026-11-16 00:00:30", zone: zone, text: "Remind me to Gym yesterday",
                     hits: [hit("yesterday", "2026-11-15 12:00")], expected: nil),
                Case(name: "\(id): over New Year", now: "2026-12-31 23:59:30", zone: zone, text: "Remind me to Call Anna tomorrow",
                     hits: [hit("tomorrow", "2027-01-01 12:00")],
                     expected: .init(title: "Call Anna", start: "2027-01-01", matched: "tomorrow")),
                Case(name: "\(id): a month name already gone this year is not rolled to next year", now: "2026-12-20 09:00", zone: zone, text: "Remind me to Call Anna on January 5",
                     hits: [hit("January 5", "2026-01-05 12:00")], expected: nil),
            ])
        }
    }

    func testTheSameInstantIsADifferentDayInAnotherZone() {
        let instant = Support.utc("2026-11-16 07:30")
        let hit = ScriptedScanner.Hit(phrase: "Monday", at: "", instant: Support.utc("2026-11-16 22:30"))
        for (zone, expected) in [(Support.berlin, "2026-11-16 23:30"), (Support.losAngeles, "2026-11-16 14:30")] {
            let parsed = NoteDateParser(scanner: ScriptedScanner([hit]))
                .parse("Remind me to Call Anna Monday", reference: instant, calendar: Support.calendar(zone))
            XCTAssertEqual(parsed.draft?.start.hour, nil, "date-only in \(zone.identifier)")
            XCTAssertEqual(parsed.draft?.start, components(String(expected.prefix(10)), zone), zone.identifier)
        }
    }

    // MARK: Words around the phrase that change its meaning

    func testNoDraftForRecurringNegatedOrNamedDates() {
        run([
            Case(name: "Black Friday", now: Self.sunday, text: "Remind me to Black Friday sale", hits: [hit("Friday", "2026-11-20 12:00")], expected: nil),
            Case(name: "Good Friday", now: Self.sunday, text: "Remind me to Church on Good Friday", hits: [hit("Friday", "2026-11-20 12:00")], expected: nil),
            Case(name: "Cyber Monday", now: Self.sunday, text: "Remind me to Shop cyber monday", hits: [hit("monday", "2026-11-16 12:00")], expected: nil),
            Case(name: "Easter Sunday", now: Self.sunday, text: "Remind me to Lunch on Easter Sunday", hits: [hit("Sunday", "2026-11-22 12:00")], expected: nil),
            Case(name: "Ash Wednesday", now: Self.sunday, text: "Remind me to Ash Wednesday service", hits: [hit("Wednesday", "2026-11-18 12:00")], expected: nil),
            Case(name: "every Monday", now: Self.sunday, text: "Remind me to Gym every Monday", hits: [hit("Monday", "2026-11-16 12:00")], expected: nil),
            Case(name: "each Friday at 9", now: Self.sunday, text: "Remind me to Standup each Friday at 9", hits: [hit("Friday at 9", "2026-11-20 09:00")], expected: nil),
            Case(name: "every other day with on", now: Self.sunday, text: "Remind me to Gym every on Monday", hits: [hit("Monday", "2026-11-16 12:00")], expected: nil),
            Case(name: "not tomorrow", now: Self.sunday, text: "Remind me to Call Anna, not tomorrow", hits: [hit("tomorrow", "2026-11-16 12:00")], expected: nil),
            Case(name: "never on Friday", now: Self.sunday, text: "Remind me to Never on Friday", hits: [hit("Friday", "2026-11-20 12:00")], expected: nil),
            Case(name: "except Friday", now: Self.sunday, text: "Remind me to Open daily except Friday", hits: [hit("Friday", "2026-11-20 12:00")], expected: nil),
            Case(name: "since Monday", now: Self.sunday, text: "Remind me to Sick since Monday", hits: [hit("Monday", "2026-11-16 12:00")], expected: nil),
            Case(name: "a word that only ends like the trigger", now: Self.sunday, text: "Remind me to Cannot call tomorrow", hits: [hit("tomorrow", "2026-11-16 12:00")],
                 expected: .init(title: "Cannot call", start: "2026-11-16", matched: "tomorrow")),
        ])
    }

    func testClockTimeFollowedByAPartOfTheDayIsNotTrusted() {
        run([
            Case(name: "9 in the evening", now: Self.sunday, text: "Remind me to Dinner tomorrow at 9 in the evening", hits: [hit("tomorrow at 9", "2026-11-16 09:00")],
                 expected: .init(title: "Dinner in the evening", start: "2026-11-16", matched: "tomorrow at 9")),
            Case(name: "9 at night", now: Self.sunday, text: "Remind me to Dinner tomorrow at 9 at night", hits: [hit("tomorrow at 9", "2026-11-16 09:00")],
                 expected: .init(title: "Dinner at night", start: "2026-11-16", matched: "tomorrow at 9")),
            Case(name: "9:30 this afternoon", now: Self.sunday, text: "Remind me to Call tomorrow at 9:30 this afternoon", hits: [hit("tomorrow at 9:30", "2026-11-16 09:30")],
                 expected: .init(title: "Call this afternoon", start: "2026-11-16", matched: "tomorrow at 9:30")),
            Case(name: "an unrelated word after the time", now: Self.sunday, text: "Remind me to Call tomorrow at 9 nightly report", hits: [hit("tomorrow at 9", "2026-11-16 09:00")],
                 expected: .init(title: "Call nightly report", start: "2026-11-16 09:00", matched: "tomorrow at 9")),
        ])
    }
}
