import Foundation
import VoiceAppCore
import XCTest

/// Synthetic scanner results isolate parser rules; none of these hits are detector recordings.
final class NoteDateParserRedesignTests: XCTestCase {
    private typealias Support = NoteTestSupport
    private typealias Hit = NoteDateParserTests.ScriptedScanner.Hit
    private let reference = Support.date("2026-11-15 21:00", Support.berlin)

    private func parse(_ text: String, phrase: String = "tomorrow", at: String = "2026-11-16 12:00", duration: TimeInterval = 0) -> ParsedNote {
        let scanner = NoteDateParserTests.ScriptedScanner([Hit(phrase: phrase, at: at, duration: duration)])
        return NoteDateParser(scanner: scanner).parse(text, reference: reference, calendar: Support.calendar(Support.berlin))
    }

    func testEveryCueWorksAnywhereAndIsRemovedWithItsConnector() {
        let rows = [
            ("remind me to", "call Anna"), ("reminder", "call Anna"), ("remember to", "call Anna"),
            ("don't forget to", "call Anna"), ("don’t forget to", "call Anna"), ("do not forget to", "call Anna"),
            ("erinnere mich daran", "Anna anzurufen"), ("erinnerung an", "Anna"),
            ("nicht vergessen", "Anna anrufen"), ("denk daran", "Anna anrufen"), ("denk dran", "Anna anrufen"),
            ("podsjeti me da", "nazovem Annu"), ("podsjetnik", "nazvati Annu"),
            ("nemoj zaboraviti", "nazvati Annu"), ("ne zaboravi", "nazvati Annu"),
            ("remind me that", "rent is payable"), ("erinnere mich an", "die Miete"),
        ]
        for (cue, task) in rows {
            for text in ["\(cue.uppercased()) \(task) tomorrow", "\(task), \(cue) tomorrow", "tomorrow \(cue) \(task)"] {
                let result = parse(text)
                XCTAssertEqual(result.text, text)
                XCTAssertEqual(result.draft?.title, task, text)
                XCTAssertEqual(result.draft?.kind, .reminder, text)
                XCTAssertEqual(result.draft?.start.day, 16, text)
            }
        }
    }

    func testNoCueMeansNoScanOrDraft() {
        for text in ["I met Anna on Friday", "support is 24/7", "jeden Morgen joggen", "Anna morgen anrufen", "nazvati Annu sutra", "call Anna tomorrow", "Meeting tomorrow from 2pm to 3pm", "unreminder tomorrow", "remind meander tomorrow", "podsjetnikar tomorrow"] {
            let scanner = NoteDateParserTests.ScriptedScanner([Hit(phrase: "tomorrow", at: "2026-11-16 12:00")])
            let result = NoteDateParser(scanner: scanner).parse(text, reference: reference, calendar: Support.calendar(Support.berlin))
            XCTAssertEqual(result.text, text)
            XCTAssertNil(result.draft, text)
            XCTAssertTrue(scanner.calls.isEmpty, text)
        }
    }

    func testMeetingWordsDoNotMakeEvents() {
        for task in ["cancel the meeting", "send the meeting notes", "appointment with Anna", "conference call", "das Meeting absagen", "die Besprechungsnotizen senden", "otkazati sastanak", "poslati bilješke sa sastanka"] {
            let text = "remind me to \(task) tomorrow at 9"
            let draft = parse(text, phrase: "tomorrow at 9", at: "2026-11-16 09:00").draft
            XCTAssertEqual(draft?.kind, .reminder, text)
            XCTAssertEqual(draft?.title, task, text)
            XCTAssertEqual(draft?.start.hour, 9, text)
            XCTAssertNil(draft?.end, text)
            XCTAssertNil(parse("\(task) tomorrow at 9", phrase: "tomorrow at 9", at: "2026-11-16 09:00").draft)
        }
    }

    func testUnconsumedDigitsInvalidateEveryHit() {
        let rows = [
            ("remind me to call", "tomorrow at 9", " 30", "2026-11-16 09:00"),
            ("remind me to call", "tomorrow at 9", "30", "2026-11-16 09:00"),
            ("erinnere mich anzurufen", "morgen um 10", " 45", "2026-11-16 10:00"),
            ("podsjeti me nazvati", "sutra u 9", " 30", "2026-11-16 09:00"),
            ("reminder call", "Friday", " the 27th", "2026-11-20 12:00"),
            ("erinnerung anrufen", "Freitag", " den 27.", "2026-11-20 12:00"),
            ("podsjetnik nazvati", "petak", " 27.", "2026-11-20 12:00"),
        ]
        for (task, phrase, suffix, at) in rows {
            XCTAssertNil(parse("\(task) \(phrase)\(suffix)", phrase: phrase, at: at).draft)
            XCTAssertNotNil(parse("\(task) \(phrase)", phrase: phrase, at: at).draft)
            XCTAssertNil(parse("call \(phrase)\(suffix)", phrase: phrase, at: at).draft)
        }
        let text = "reminder tomorrow, tomorrow 30"
        // A separate range is needed: both dates are equal, but the second truncated phrase is unsafe.
        let hits = [ScannedDate(range: text.range(of: "tomorrow,")!, date: Support.date("2026-11-16 12:00", Support.berlin)),
                    ScannedDate(range: text.range(of: "tomorrow", options: .backwards)!, date: Support.date("2026-11-16 12:00", Support.berlin))]
        struct Scanner: DateScanner {
            let hits: [ScannedDate]
            func scan(_ text: String, reference: Date, timeZone: TimeZone) -> [ScannedDate] { hits }
        }
        XCTAssertNil(NoteDateParser(scanner: Scanner(hits: hits)).parse(text, reference: reference, calendar: Support.calendar(Support.berlin)).draft)
    }

    func testNextWeekdaysAreRefusedEvenWhenTheDetectorOmitsNext() {
        for (next, weekday) in [("next", "Monday"), ("nächsten", "Montag"), ("sljedeći", "ponedjeljak")] {
            for phrase in ["\(next) \(weekday)", weekday] {
                XCTAssertNil(parse("reminder call \(next) \(weekday)", phrase: phrase, at: "2026-11-23 12:00").draft)
                XCTAssertNil(parse("call \(next) \(weekday)", phrase: phrase, at: "2026-11-23 12:00").draft)
            }
            XCTAssertNotNil(parse("reminder call \(weekday)", phrase: weekday).draft)
        }
        XCTAssertNotNil(parse("reminder call this Friday", phrase: "this Friday", at: "2026-11-20 12:00").draft)
    }

    func testNextWeekdaysAcrossLanguagesAndCroatianCases() {
        let rows = [
            ("next", "Sunday", 22), ("next", "Monday", 16), ("next", "Tuesday", 17),
            ("next", "Wednesday", 18), ("next", "Thursday", 19), ("next", "Friday", 20), ("next", "Saturday", 21),
            ("nächsten", "Sonntag", 22), ("nächsten", "Montag", 16), ("nächsten", "Dienstag", 17),
            ("nächsten", "Mittwoch", 18), ("nächsten", "Donnerstag", 19), ("nächsten", "Freitag", 20), ("nächsten", "Samstag", 21),
            ("sljedeće", "nedjelje", 22), ("sljedećeg", "ponedjeljka", 16), ("sljedećeg", "utorka", 17),
            ("sljedeće", "srijede", 18), ("sljedećeg", "četvrtka", 19), ("sljedećeg", "petka", 20), ("sljedeće", "subote", 21),
        ]
        for (modifier, weekday, day) in rows {
            let at = "2026-11-\(day) 12:00"
            XCTAssertNil(parse("reminder call \(modifier) \(weekday)", phrase: weekday, at: at).draft, weekday)
            XCTAssertEqual(parse("reminder call \(weekday)", phrase: weekday, at: at).draft?.start.day, day, weekday)
        }
        for now in ["2026-11-20 12:00", "2026-11-21 12:00"] {
            let scanner = NoteDateParserTests.ScriptedScanner([Hit(phrase: "next Monday", at: "2026-11-30 12:00")])
            XCTAssertNil(NoteDateParser(scanner: scanner).parse("remind me to call next Monday", reference: Support.date(now, Support.berlin), calendar: Support.calendar(Support.berlin)).draft)
        }
    }

    func testWeekdayMustAgreeWithResolvedDate() {
        for phrase in ["Friday, November 21", "Freitag, den 21. November", "petak 21.11.2026"] {
            XCTAssertNil(parse("reminder call \(phrase)", phrase: phrase, at: "2026-11-21 12:00").draft)
            XCTAssertNil(parse("call \(phrase)", phrase: phrase, at: "2026-11-21 12:00").draft)
        }
        for weekday in ["Saturday", "Samstag", "subota"] {
            XCTAssertNotNil(parse("reminder call \(weekday)", phrase: weekday, at: "2026-11-21 12:00").draft)
        }
    }

    func testContradictingWeekdayOnADuplicateHitIsRefused() {
        let text = "reminder call Monday or Friday"
        let scanner = NoteDateParserTests.ScriptedScanner([
            Hit(phrase: "Monday", at: "2026-11-16 12:00"),
            Hit(phrase: "Friday", at: "2026-11-16 12:00"),
        ])
        XCTAssertNil(NoteDateParser(scanner: scanner).parse(text, reference: reference, calendar: Support.calendar(Support.berlin)).draft)
    }

    func testNumericDayMonthNeedsAYear() {
        for phrase in ["24/7", "13/8", "16/9", "10/10", "12/24", "24.7", "13-8"] {
            for cue in ["remind me", "erinnerung", "podsjetnik"] {
                XCTAssertNil(parse("\(cue) call \(phrase)", phrase: phrase, at: "2027-07-24 12:00").draft)
                XCTAssertNil(parse("call \(phrase)", phrase: phrase, at: "2027-07-24 12:00").draft)
            }
        }
        XCTAssertNotNil(parse("reminder call 24/7/2027", phrase: "24/7/2027", at: "2027-07-24 12:00").draft)
        XCTAssertNotNil(parse("reminder call tomorrow 10:00–11:00", phrase: "tomorrow 10:00–11:00", at: "2026-11-16 10:00", duration: 3600).draft?.end)
    }

    func testRecurrenceAndNegationOutsideCuesAreRefused() {
        for word in ["every", "each", "not", "never", "except", "since", "jeden", "jede", "jedes", "nicht", "kein", "svaki", "svake", "svakog", "ne"] {
            XCTAssertNil(parse("reminder \(word) call tomorrow").draft, word)
            XCTAssertNil(parse("\(word) call tomorrow").draft, word)
        }
        for cue in ["don't forget", "don’t forget", "do not forget", "nicht vergessen", "ne zaboravi", "nemoj zaboraviti"] {
            XCTAssertNotNil(parse("\(cue) call tomorrow").draft, cue)
            XCTAssertNil(parse("\(cue) call not tomorrow").draft, cue)
        }
    }

    func testDatePrepositionsAreRemovedInGermanAndCroatianTitles() {
        for (text, phrase, title) in [
            ("Erinnerung Milch am Freitag kaufen", "Freitag", "Milch kaufen"),
            ("Podsjetnik kupiti mlijeko u petak", "petak", "kupiti mlijeko"),
            ("Erinnere mich Anna morgen um 9 anzurufen", "morgen um 9", "Anna anzurufen"),
        ] {
            let at = phrase == "morgen um 9" ? "2026-11-16 09:00" : "2026-11-20 12:00"
            XCTAssertEqual(parse(text, phrase: phrase, at: at).draft?.title, title)
        }
    }

    func testDurationWithoutTwoClockTimesDoesNotMakeAnEvent() {
        let draft = parse("reminder trip tomorrow at 9am", phrase: "tomorrow at 9am", at: "2026-11-16 09:00", duration: 86_400).draft
        XCTAssertEqual(draft?.kind, .reminder)
        XCTAssertNil(draft?.end)
    }

    func testSpanEndNearDSTIsDroppedWhileSafeStartIsKept() {
        let draft = parse("reminder call on March 28 2027 from 0:30 to 1:30", phrase: "March 28 2027 from 0:30 to 1:30", at: "2027-03-28 00:30", duration: 3600).draft
        XCTAssertEqual(draft?.start.hour, 0)
        XCTAssertEqual(draft?.start.minute, 30)
        XCTAssertEqual(draft?.kind, .reminder)
        XCTAssertNil(draft?.end)
    }
}
