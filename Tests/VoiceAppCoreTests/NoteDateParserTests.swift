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
}
