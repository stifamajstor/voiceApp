import Foundation
import VoiceAppCore
import XCTest

/// Rules of the note parser, driven by a scripted scanner so every reference date, zone and DST edge is fixed.
/// The scripted hits are what NSDataDetector returned for the same phrases when they were recorded (see
/// SystemDateScannerTests for the live checks), including its surprises: it moves "at 7" to 19:00, rolls
/// "February 30" over to March 2, and answers "tomorrow at midnight" with the day after.
final class NoteDateParserTests: XCTestCase {
    private typealias Support = NoteTestSupport

    /// Plays back what the detector is known to return; the zone passed to `scan` is the one `at` is read in.
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
        private var seen: [(text: String, reference: Date, timeZone: TimeZone, locale: Locale)] = []

        init(_ hits: [Hit]) { self.hits = hits }

        var calls: [(text: String, reference: Date, timeZone: TimeZone, locale: Locale)] {
            lock.lock(); defer { lock.unlock() }
            return seen
        }

        func scan(_ text: String, reference: Date, timeZone: TimeZone, locale: Locale) -> [ScannedDate] {
            lock.lock(); seen.append((text, reference, timeZone, locale)); lock.unlock()
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
        var locale = "en_US"
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
                .parse(c.text, reference: Support.date(c.now, c.zone), calendar: Support.calendar(c.zone), locale: Locale(identifier: c.locale))
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
            Case(name: "tomorrow with a digit time", now: Self.sunday, text: "Call Anna tomorrow at 9",
                 hits: [hit("tomorrow at 9", "2026-11-16 09:00")],
                 expected: .init(title: "Call Anna", start: "2026-11-16 09:00", matched: "tomorrow at 9")),
            Case(name: "tomorrow alone keeps a date without a time", now: Self.sunday, text: "Buy milk tomorrow",
                 hits: [hit("tomorrow", "2026-11-16 12:00")],
                 expected: .init(title: "Buy milk", start: "2026-11-16", matched: "tomorrow")),
            Case(name: "weekday", now: Self.sunday, text: "Remind me on Friday to call Anna",
                 hits: [hit("Friday", "2026-11-20 12:00")],
                 expected: .init(title: "call Anna", start: "2026-11-20", matched: "Friday")),
            Case(name: "weekday with a digit time", now: Self.sunday, text: "Send the invoice Friday at 9",
                 hits: [hit("Friday at 9", "2026-11-20 09:00")],
                 expected: .init(title: "Send the invoice", start: "2026-11-20 09:00", matched: "Friday at 9")),
            Case(name: "next Friday", now: Self.sunday, text: "Book flights next Friday",
                 hits: [hit("next Friday", "2026-11-20 12:00")],
                 expected: .init(title: "Book flights", start: "2026-11-20", matched: "next Friday")),
            Case(name: "in three days", now: Self.sunday, text: "Water the plants in 3 days",
                 hits: [hit("in 3 days", "2026-11-18 12:00")],
                 expected: .init(title: "Water the plants", start: "2026-11-18", matched: "in 3 days")),
            Case(name: "month and day with a time", now: Self.sunday, text: "Pay rent on November 20 at 10:30",
                 hits: [hit("November 20 at 10:30", "2026-11-20 10:30")],
                 expected: .init(title: "Pay rent", start: "2026-11-20 10:30", matched: "November 20 at 10:30")),
            Case(name: "month and day without a year, still ahead", now: "2026-10-01 09:00", text: "Renew passport on Nov 13",
                 hits: [hit("Nov 13", "2026-11-13 12:00")],
                 expected: .init(title: "Renew passport", start: "2026-11-13", matched: "Nov 13")),
            Case(name: "date with a year", now: Self.sunday, text: "File taxes on November 13, 2027",
                 hits: [hit("November 13, 2027", "2027-11-13 12:00")],
                 expected: .init(title: "File taxes", start: "2027-11-13", matched: "November 13, 2027")),
            Case(name: "ISO date", now: Self.sunday, text: "Deadline 2027-03-04",
                 hits: [hit("2027-03-04", "2027-03-04 12:00")],
                 expected: .init(title: "Deadline", start: "2027-03-04", matched: "2027-03-04")),
            Case(name: "leap day in a leap year", now: "2027-11-15 09:00", text: "Party on Feb 29 2028",
                 hits: [hit("Feb 29 2028", "2028-02-29 12:00")],
                 expected: .init(title: "Party", start: "2028-02-29", matched: "Feb 29 2028")),
            Case(name: "thirty days ahead landing on the 2nd is not a rollover", now: "2026-12-03 09:00", text: "Check in 30 days",
                 hits: [hit("in 30 days", "2027-01-02 12:00")],
                 expected: .init(title: "Check", start: "2027-01-02", matched: "in 30 days")),
            Case(name: "today stays a date even late in the evening", now: Self.sunday, text: "Buy milk today",
                 hits: [hit("today", "2026-11-15 12:00")],
                 expected: .init(title: "Buy milk", start: "2026-11-15", matched: "today")),
            Case(name: "later today", now: Self.sunday, text: "Call Anna today at 22:00",
                 hits: [hit("today at 22:00", "2026-11-15 22:00")],
                 expected: .init(title: "Call Anna", start: "2026-11-15 22:00", matched: "today at 22:00")),
        ])
    }

    // MARK: Times are only kept when the digits in the note say so

    func testClockTimeIsKeptOnlyWhenItCanBeReadBackFromTheNote() {
        run([
            Case(name: "the detector moves a bare 7 to 19:00", now: Self.sunday, text: "Gym tomorrow at 7",
                 hits: [hit("tomorrow at 7", "2026-11-16 19:00")],
                 expected: .init(title: "Gym", start: "2026-11-16", matched: "tomorrow at 7")),
            Case(name: "pm is explicit", now: Self.sunday, text: "Gym tomorrow at 7pm",
                 hits: [hit("tomorrow at 7pm", "2026-11-16 19:00")],
                 expected: .init(title: "Gym", start: "2026-11-16 19:00", matched: "tomorrow at 7pm")),
            Case(name: "pm with a space and dots", now: Self.sunday, text: "Gym tomorrow at 7 p.m.",
                 hits: [hit("tomorrow at 7 p.m.", "2026-11-16 19:00")],
                 expected: .init(title: "Gym", start: "2026-11-16 19:00", matched: "tomorrow at 7 p.m.")),
            Case(name: "24-hour clock", now: Self.sunday, text: "Gym tomorrow at 19:00",
                 hits: [hit("tomorrow at 19:00", "2026-11-16 19:00")],
                 expected: .init(title: "Gym", start: "2026-11-16 19:00", matched: "tomorrow at 19:00")),
            Case(name: "a bare 3 moved to 15:00", now: Self.sunday, text: "Dentist tomorrow at 3",
                 hits: [hit("tomorrow at 3", "2026-11-16 15:00")],
                 expected: .init(title: "Dentist", start: "2026-11-16", matched: "tomorrow at 3")),
            Case(name: "a bare 9 stays 9", now: Self.sunday, text: "Dentist tomorrow at 9",
                 hits: [hit("tomorrow at 9", "2026-11-16 09:00")],
                 expected: .init(title: "Dentist", start: "2026-11-16 09:00", matched: "tomorrow at 9")),
            Case(name: "minutes must match", now: Self.sunday, text: "Dentist tomorrow at 9:15",
                 hits: [hit("tomorrow at 9:15", "2026-11-16 09:30")],
                 expected: .init(title: "Dentist", start: "2026-11-16", matched: "tomorrow at 9:15")),
            Case(name: "the day number is not an hour", now: "2026-10-01 09:00", text: "Dentist November 13 at 1",
                 hits: [hit("November 13 at 1", "2026-11-13 13:00")],
                 expected: .init(title: "Dentist", start: "2026-11-13", matched: "November 13 at 1")),
            Case(name: "explicit noon", now: Self.sunday, text: "Lunch tomorrow at 12:00",
                 hits: [hit("tomorrow at 12:00", "2026-11-16 12:00")],
                 expected: .init(title: "Lunch", start: "2026-11-16 12:00", matched: "tomorrow at 12:00")),
            Case(name: "the word noon is not a digit time", now: Self.sunday, text: "Lunch tomorrow at noon",
                 hits: [hit("tomorrow at noon", "2026-11-16 12:00")],
                 expected: .init(title: "Lunch", start: "2026-11-16", matched: "tomorrow at noon")),
            Case(name: "a part of the day is not a clock time", now: Self.sunday, text: "Gym tomorrow morning",
                 hits: [hit("tomorrow morning", "2026-11-16 09:00")],
                 expected: .init(title: "Gym", start: "2026-11-16", matched: "tomorrow morning")),
            Case(name: "tonight is today without a time", now: Self.sunday, text: "Gym tonight",
                 hits: [hit("tonight", "2026-11-15 18:00")],
                 expected: .init(title: "Gym", start: "2026-11-15", matched: "tonight")),
            Case(name: "midnight lands on the next day, so no draft", now: Self.sunday, text: "Gym tomorrow at midnight",
                 hits: [hit("tomorrow at midnight", "2026-11-17 00:00")],
                 expected: nil),
            Case(name: "explicit 0:30", now: Self.sunday, text: "Flight tomorrow at 0:30",
                 hits: [hit("tomorrow at 0:30", "2026-11-16 00:30")],
                 expected: .init(title: "Flight", start: "2026-11-16 00:30", matched: "tomorrow at 0:30")),
            Case(name: "words for the time are left to the day", now: Self.sunday, text: "Call Anna Friday at nine",
                 hits: [hit("Friday", "2026-11-20 12:00")],
                 expected: .init(title: "Call Anna at nine", start: "2026-11-20", matched: "Friday")),
        ])
    }

    // MARK: Events need a time span or a meeting with a time

    func testEventsNeedASpanOrANamedMeetingWithATime() {
        run([
            Case(name: "span with pm on both ends", now: Self.sunday, text: "Sync tomorrow from 3pm to 4pm",
                 hits: [hit("tomorrow from 3pm to 4pm", "2026-11-16 15:00", duration: 3600)],
                 expected: .init(kind: .event, title: "Sync", start: "2026-11-16 15:00", end: "2026-11-16 16:00", matched: "tomorrow from 3pm to 4pm")),
            Case(name: "pm on the end covers the start", now: Self.sunday, text: "Sync tomorrow from 3 to 4pm",
                 hits: [hit("tomorrow from 3 to 4pm", "2026-11-16 15:00", duration: 3600)],
                 expected: .init(kind: .event, title: "Sync", start: "2026-11-16 15:00", end: "2026-11-16 16:00", matched: "tomorrow from 3 to 4pm")),
            Case(name: "24-hour span", now: Self.sunday, text: "Sync tomorrow from 15 to 16",
                 hits: [hit("tomorrow from 15 to 16", "2026-11-16 15:00", duration: 3600)],
                 expected: .init(kind: .event, title: "Sync", start: "2026-11-16 15:00", end: "2026-11-16 16:00", matched: "tomorrow from 15 to 16")),
            Case(name: "span with minutes", now: Self.sunday, text: "Sync tomorrow from 9:30 to 10:15",
                 hits: [hit("tomorrow from 9:30 to 10:15", "2026-11-16 09:30", duration: 2700)],
                 expected: .init(kind: .event, title: "Sync", start: "2026-11-16 09:30", end: "2026-11-16 10:15", matched: "tomorrow from 9:30 to 10:15")),
            Case(name: "span across midnight", now: Self.sunday, text: "Party tomorrow from 11pm to 1am",
                 hits: [hit("tomorrow from 11pm to 1am", "2026-11-16 23:00", duration: 7200)],
                 expected: .init(kind: .event, title: "Party", start: "2026-11-16 23:00", end: "2026-11-17 01:00", matched: "tomorrow from 11pm to 1am")),
            Case(name: "bare span the detector moved to the afternoon is only a reminder", now: Self.sunday, text: "Sync tomorrow from 3 to 4",
                 hits: [hit("tomorrow from 3 to 4", "2026-11-16 15:00", duration: 3600)],
                 expected: .init(title: "Sync", start: "2026-11-16", matched: "tomorrow from 3 to 4")),
            Case(name: "end the detector moved to 17:00 drops the span but keeps a start that matches", now: Self.sunday, text: "Workshop tomorrow from 9 to 5",
                 hits: [hit("tomorrow from 9 to 5", "2026-11-16 09:00", duration: 28800)],
                 expected: .init(title: "Workshop", start: "2026-11-16 09:00", matched: "tomorrow from 9 to 5")),
            Case(name: "a span of more than a day is not trusted", now: Self.sunday, text: "Trip tomorrow at 9am",
                 hits: [hit("tomorrow at 9am", "2026-11-16 09:00", duration: 90000)],
                 expected: .init(title: "Trip", start: "2026-11-16 09:00", matched: "tomorrow at 9am")),
            Case(name: "a span without a clock time is ignored", now: Self.sunday, text: "A week from Friday",
                 hits: [hit("from Friday", "2026-11-20 12:00", duration: 3600)],
                 expected: .init(title: "A week", start: "2026-11-20", matched: "from Friday")),
            Case(name: "meeting with a time", now: Self.sunday, text: "Meeting with Anna tomorrow at 3pm",
                 hits: [hit("tomorrow at 3pm", "2026-11-16 15:00")],
                 expected: .init(kind: .event, title: "Meeting with Anna", start: "2026-11-16 15:00", matched: "tomorrow at 3pm")),
            Case(name: "appointment with a time", now: Self.sunday, text: "Dentist appointment on November 20 at 9:30",
                 hits: [hit("November 20 at 9:30", "2026-11-20 09:30")],
                 expected: .init(kind: .event, title: "Dentist appointment", start: "2026-11-20 09:30", matched: "November 20 at 9:30")),
            Case(name: "call with someone, with a time", now: Self.sunday, text: "Call with Anna tomorrow at 6pm",
                 hits: [hit("tomorrow at 6pm", "2026-11-16 18:00")],
                 expected: .init(kind: .event, title: "Call with Anna", start: "2026-11-16 18:00", matched: "tomorrow at 6pm")),
            Case(name: "meeting is a keyword in any case", now: Self.sunday, text: "TEAM MEETING Friday at 2pm",
                 hits: [hit("Friday at 2pm", "2026-11-20 14:00")],
                 expected: .init(kind: .event, title: "TEAM MEETING", start: "2026-11-20 14:00", matched: "Friday at 2pm")),
            Case(name: "calling someone is a to-do, not an event", now: Self.sunday, text: "Call mom tomorrow at 6pm",
                 hits: [hit("tomorrow at 6pm", "2026-11-16 18:00")],
                 expected: .init(title: "Call mom", start: "2026-11-16 18:00", matched: "tomorrow at 6pm")),
            Case(name: "a meeting without a time is a reminder", now: Self.sunday, text: "Meeting with Anna tomorrow",
                 hits: [hit("tomorrow", "2026-11-16 12:00")],
                 expected: .init(title: "Meeting with Anna", start: "2026-11-16", matched: "tomorrow")),
            Case(name: "a meeting whose time cannot be trusted is a reminder", now: Self.sunday, text: "Meeting tomorrow at 7",
                 hits: [hit("tomorrow at 7", "2026-11-16 19:00")],
                 expected: .init(title: "Meeting", start: "2026-11-16", matched: "tomorrow at 7")),
            Case(name: "plural keyword", now: Self.sunday, text: "Meetings notes tomorrow at 9",
                 hits: [hit("tomorrow at 9", "2026-11-16 09:00")],
                 expected: .init(kind: .event, title: "Meetings notes", start: "2026-11-16 09:00", matched: "tomorrow at 9")),
            Case(name: "word that merely contains the keyword", now: Self.sunday, text: "Recall the appointmentsheet tomorrow at 9",
                 hits: [hit("tomorrow at 9", "2026-11-16 09:00")],
                 expected: .init(title: "Recall the appointmentsheet", start: "2026-11-16 09:00", matched: "tomorrow at 9")),
        ])
    }

    // MARK: No draft

    func testNoDraftWhenNoDateIsFound() {
        run([
            Case(name: "plain note", now: Self.sunday, text: "Buy milk", hits: [], expected: nil),
            Case(name: "empty", now: Self.sunday, text: "", hits: [], expected: nil),
            Case(name: "whitespace only", now: Self.sunday, text: "  \n\t  ", hits: [hit("tomorrow", "2026-11-16 12:00")], expected: nil),
            Case(name: "next week is not known to the detector", now: Self.sunday, text: "Plan the sprint next week", hits: [], expected: nil),
            Case(name: "end of the month is not known to the detector", now: Self.sunday, text: "Pay rent at the end of the month", hits: [], expected: nil),
            Case(name: "in two hours is not known to the detector", now: Self.sunday, text: "Call Anna in two hours", hits: [], expected: nil),
            Case(name: "the 13th alone is not known to the detector", now: Self.sunday, text: "Pay rent on the 13th", hits: [], expected: nil),
        ])
    }

    func testNoDraftForATimeWithoutADay() {
        run([
            Case(name: "9am", now: Self.sunday, text: "Call Anna at 9am", hits: [hit("9am", "2026-11-16 09:00")], expected: nil),
            Case(name: "10:30", now: Self.sunday, text: "Call Anna at 10:30", hits: [hit("10:30", "2026-11-15 22:30")], expected: nil),
            Case(name: "o'clock", now: Self.sunday, text: "Call Anna at 9 o'clock", hits: [hit("9 o'clock", "2026-11-16 09:00")], expected: nil),
            Case(name: "dotted time", now: Self.sunday, text: "Call Anna at 9.30", hits: [hit("9.30", "2026-11-16 09:30")], expected: nil),
            Case(name: "span without a day", now: Self.sunday, text: "Sync from 3pm to 4pm", hits: [hit("from 3pm to 4pm", "2026-11-16 15:00", duration: 3600)], expected: nil),
            Case(name: "dashed span without a day", now: Self.sunday, text: "Sync 3-4pm", hits: [hit("3-4pm", "2026-11-16 15:00", duration: 3600)], expected: nil),
            Case(name: "German time without a day", now: Self.sunday, locale: "de_DE", text: "um 9 Uhr anrufen", hits: [hit("9 Uhr", "2026-11-16 09:00")], expected: nil),
            Case(name: "Croatian clock time the detector finds under an English locale", now: Self.sunday, text: "sutra u 10:30",
                 hits: [hit("10:30", "2026-11-15 22:30")], expected: nil),
            Case(name: "a dotted date is not a time", now: "2026-10-01 09:00", text: "Pay 13.11.2026",
                 hits: [hit("13.11.2026", "2026-11-13 12:00")],
                 expected: .init(title: "Pay", start: "2026-11-13", matched: "13.11.2026")),
        ])
    }

    func testNoDraftForADateInThePast() {
        run([
            Case(name: "earlier this month", now: Self.sunday, text: "Call Anna on November 13", hits: [hit("November 13", "2026-11-13 12:00")], expected: nil),
            Case(name: "yesterday", now: Self.sunday, text: "Call Anna yesterday", hits: [hit("yesterday", "2026-11-14 12:00")], expected: nil),
            Case(name: "last Friday", now: Self.sunday, text: "Met Anna last Friday", hits: [hit("last Friday", "2026-11-06 12:00")], expected: nil),
            Case(name: "earlier today", now: Self.sunday, text: "Call Anna today at 9", hits: [hit("today at 9", "2026-11-15 09:00")], expected: nil),
            Case(name: "exactly now", now: Self.sunday, text: "Call Anna today at 21:00", hits: [hit("today at 21:00", "2026-11-15 21:00")], expected: nil),
            Case(name: "one minute ahead", now: Self.sunday, text: "Call Anna today at 21:01", hits: [hit("today at 21:01", "2026-11-15 21:01")],
                 expected: .init(title: "Call Anna", start: "2026-11-15 21:01", matched: "today at 21:01")),
            Case(name: "a year ago", now: Self.sunday, text: "Born on November 13, 2025", hits: [hit("November 13, 2025", "2025-11-13 12:00")], expected: nil),
        ])
    }

    func testNoDraftForADateMoreThanTwoYearsAway() {
        run([
            Case(name: "on the limit", now: Self.sunday, text: "Party on Nov 15 2028", hits: [hit("Nov 15 2028", "2028-11-15 12:00")],
                 expected: .init(title: "Party", start: "2028-11-15", matched: "Nov 15 2028")),
            Case(name: "a day past the limit", now: Self.sunday, text: "Party on Nov 16 2028", hits: [hit("Nov 16 2028", "2028-11-16 12:00")], expected: nil),
            Case(name: "far away", now: Self.sunday, text: "Party on November 13, 2030", hits: [hit("November 13, 2030", "2030-11-13 12:00")], expected: nil),
        ])
    }

    func testNoDraftWhenSeveralDifferentDatesAreFound() {
        run([
            Case(name: "two days with times", now: Self.sunday, text: "Monday at 9 and Tuesday at 10",
                 hits: [hit("Monday at 9", "2026-11-16 09:00"), hit("Tuesday at 10", "2026-11-17 10:00")], expected: nil),
            Case(name: "either of two days", now: Self.sunday, text: "Friday or Saturday",
                 hits: [hit("Friday", "2026-11-20 12:00"), hit("Saturday", "2026-11-21 12:00")], expected: nil),
            Case(name: "a day and a time apart from it", now: Self.sunday, text: "Meeting Friday, starts at 9am",
                 hits: [hit("Friday", "2026-11-20 12:00"), hit("9am", "2026-11-16 09:00")], expected: nil),
            Case(name: "tomorrow and the day after", now: Self.sunday, text: "tomorrow and the day after tomorrow",
                 hits: [hit("tomorrow", "2026-11-16 12:00"), hit("the day after tomorrow", "2026-11-17 12:00")], expected: nil),
            Case(name: "the same day twice is one date", now: Self.sunday, text: "Tomorrow I will do it tomorrow",
                 hits: [hit("Tomorrow", "2026-11-16 12:00"), hit("tomorrow", "2026-11-16 12:00")],
                 expected: .init(title: "I will do it tomorrow", start: "2026-11-16", matched: "Tomorrow")),
        ])
    }

    func testNoDraftWhenTheDetectorRolledAnImpossibleDateForward() {
        run([
            Case(name: "February 30", now: "2027-01-10 12:00", text: "Pay on February 30", hits: [hit("February 30", "2027-03-02 12:00")], expected: nil),
            Case(name: "February 29 in a common year", now: Self.sunday, text: "Party on Feb 29 2027", hits: [hit("Feb 29 2027", "2027-03-01 12:00")], expected: nil),
            Case(name: "November 31", now: Self.sunday, text: "Pay on November 31", hits: [hit("November 31", "2026-12-01 12:00")], expected: nil),
            Case(name: "April 31", now: "2027-03-10 12:00", text: "Pay on 31 April", hits: [hit("31 April", "2027-05-01 12:00")], expected: nil),
            Case(name: "numeric 02/30/2027", now: "2027-01-10 12:00", text: "Pay on 02/30/2027", hits: [hit("02/30/2027", "2027-03-02 12:00")], expected: nil),
            Case(name: "the 31st of a month that has one", now: Self.sunday, text: "Pay on December 31", hits: [hit("December 31", "2026-12-31 12:00")],
                 expected: .init(title: "Pay", start: "2026-12-31", matched: "December 31")),
        ])
    }

    func testNoDraftForNumericDatesWhoseDayAndMonthCouldBeSwapped() {
        run([
            Case(name: "3/4/2027", now: Self.sunday, text: "Pay on 3/4/2027", hits: [hit("3/4/2027", "2027-03-04 12:00")], expected: nil),
            Case(name: "03.04.2027", now: Self.sunday, text: "Pay on 03.04.2027", hits: [hit("03.04.2027", "2027-04-03 12:00")], expected: nil),
            Case(name: "3-4-2027", now: Self.sunday, text: "Pay on 3-4-2027", hits: [hit("3-4-2027", "2027-03-04 12:00")], expected: nil),
            Case(name: "3/4/27", now: Self.sunday, text: "Pay on 3/4/27", hits: [hit("3/4/27", "2027-03-04 12:00")], expected: nil),
            Case(name: "4/5 with no year", now: Self.sunday, text: "Pay on 4/5", hits: [hit("4/5", "2027-04-05 12:00")], expected: nil),
            Case(name: "13/3/2027 can only be day first", now: Self.sunday, text: "Pay on 13/3/2027", hits: [hit("13/3/2027", "2027-03-13 12:00")],
                 expected: .init(title: "Pay", start: "2027-03-13", matched: "13/3/2027")),
            Case(name: "3/13/2027 can only be month first", now: Self.sunday, text: "Pay on 3/13/2027", hits: [hit("3/13/2027", "2027-03-13 12:00")],
                 expected: .init(title: "Pay", start: "2027-03-13", matched: "3/13/2027")),
            Case(name: "3/3/2027 reads the same both ways", now: Self.sunday, text: "Pay on 3/3/2027", hits: [hit("3/3/2027", "2027-03-03 12:00")],
                 expected: .init(title: "Pay", start: "2027-03-03", matched: "3/3/2027")),
            Case(name: "11/13 with no year", now: "2026-10-01 09:00", text: "Pay on 11/13", hits: [hit("11/13", "2026-11-13 12:00")],
                 expected: .init(title: "Pay", start: "2026-11-13", matched: "11/13")),
            Case(name: "a dashed span after a day is not a date", now: Self.sunday, text: "Sync tomorrow 3-4pm",
                 hits: [hit("tomorrow 3-4pm", "2026-11-16 15:00", duration: 3600)],
                 expected: .init(title: "Sync", start: "2026-11-16", matched: "tomorrow 3-4pm")),
        ])
    }

    func testNoDraftWhenThePhraseNamesItsOwnTimeZone() {
        run([
            Case(name: "9am PST", now: Self.sunday, text: "Call Anna tomorrow at 9am PST",
                 hits: [.init(phrase: "tomorrow at 9am PST", at: "2026-11-16 18:00", namesTimeZone: true)], expected: nil),
        ])
    }

    func testNoDraftForAnUnsupportedCalendar() {
        let reference = Support.date(Self.sunday, Support.berlin)
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = Support.berlin
        let parsed = NoteDateParser(scanner: ScriptedScanner([hit("tomorrow", "2026-11-16 12:00")]))
            .parse("Buy milk tomorrow", reference: reference, calendar: buddhist, locale: Support.en)
        XCTAssertNil(parsed.draft)
    }

    // MARK: Hostile input

    func testVeryLongNotesAreNotScanned() {
        let scanner = ScriptedScanner([hit("tomorrow", "2026-11-16 12:00")])
        let parser = NoteDateParser(scanner: scanner)
        let reference = Support.date(Self.sunday, Support.berlin)
        let calendar = Support.calendar(Support.berlin)

        let tooLong = String(repeating: "a", count: NoteDateParser.maximumNoteLength - 8) + " tomorrow"
        XCTAssertNil(parser.parse(tooLong, reference: reference, calendar: calendar, locale: Support.en).draft)
        XCTAssertEqual(scanner.calls.count, 0)

        let atTheLimit = String(repeating: "a", count: NoteDateParser.maximumNoteLength - 9) + " tomorrow"
        XCTAssertEqual(atTheLimit.utf16.count, NoteDateParser.maximumNoteLength)
        let draft = parser.parse(atTheLimit, reference: reference, calendar: calendar, locale: Support.en).draft
        XCTAssertNotNil(draft)
        XCTAssertEqual(scanner.calls.count, 1)
    }

    func testBlankNotesAreNotScanned() {
        let scanner = ScriptedScanner([hit("tomorrow", "2026-11-16 12:00")])
        let parser = NoteDateParser(scanner: scanner)
        for text in ["", " ", "\n\n", " \t\n "] {
            XCTAssertNil(parser.parse(text, reference: Support.date(Self.sunday, Support.berlin), calendar: Support.calendar(Support.berlin), locale: Support.en).draft)
        }
        XCTAssertEqual(scanner.calls.count, 0)
    }

    func testScannerGetsTheCallersReferenceZoneAndLocale() {
        let scanner = ScriptedScanner([])
        let reference = Support.date(Self.sunday, Support.losAngeles)
        _ = NoteDateParser(scanner: scanner)
            .parse("Buy milk tomorrow", reference: reference, calendar: Support.calendar(Support.losAngeles), locale: Locale(identifier: "hr_HR"))
        XCTAssertEqual(scanner.calls.count, 1)
        XCTAssertEqual(scanner.calls.first?.text, "Buy milk tomorrow")
        XCTAssertEqual(scanner.calls.first?.reference, reference)
        XCTAssertEqual(scanner.calls.first?.timeZone, Support.losAngeles)
        XCTAssertEqual(scanner.calls.first?.locale.identifier, "hr_HR")
    }
}
