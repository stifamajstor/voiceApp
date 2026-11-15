import Foundation
import VoiceAppCore
import XCTest

/// Grammar rules with synthetic scanner results, independent of the system's languages and clock.
final class NoteDateGrammarTests: XCTestCase {
    private typealias Support = NoteTestSupport
    private let reference = Support.date("2026-11-15 21:00", Support.berlin)

    private func parse(_ text: String, _ phrase: String, at: String = "2026-11-20 12:00", duration: TimeInterval = 0) -> ParsedNote {
        let scanner = ScriptedDateScanner([.init(phrase: phrase, at: at, duration: duration)])
        return NoteDateParser(scanner: scanner).parse(text, reference: reference, calendar: Support.calendar(Support.berlin))
    }

    func testOpeningVerbAndLabelCues() {
        let verbs = ["remind me", "remember to", "don't forget", "don’t forget", "do not forget", "erinnere mich", "nicht vergessen", "denk daran", "denk dran", "podsjeti me", "nemoj zaboraviti", "ne zaboravi"]
        for cue in verbs {
            for prefix in ["", "Please ", "hey ", "ok ", "okay ", "also ", "and ", "bitte ", "und ", "molim ", "i ", "Other thought. ", "Other! ", "Other? ", "Other: ", "Other; ", "Other\n"] {
                XCTAssertNotNil(parse("\(prefix)\(cue) on Friday", "Friday").draft, prefix + cue)
            }
            for prefix in ["I always ", "the note said ", "please hey ", "Someone ", "Other, "] {
                XCTAssertNil(parse("\(prefix)\(cue) on Friday", "Friday").draft, prefix + cue)
            }
        }
        for label in ["reminder", "Erinnerung", "podsjetnik"] {
            for connector in [":", " to", " for", " that", " an", " dass", " für", " da", " za"] {
                XCTAssertNotNil(parse("\(label)\(connector) on Friday", "Friday").draft)
            }
            XCTAssertNil(parse("\(label) on Friday", "Friday").draft)
            XCTAssertNil(parse("please \(label): on Friday", "Friday").draft)
        }
    }

    func testQuestionsAndNarrativesGiveNoDraft() {
        for word in ["what", "why", "how", "when", "where", "who", "which", "whether", "if", "was", "warum", "wie", "wann", "wo", "wer", "ob", "što", "zašto", "kako", "kad", "kada", "gdje", "tko"] {
            XCTAssertNil(parse("remind me \(word) happened on Monday", "Monday").draft, word)
        }
        for (text, phrase) in [
            ("the reminder I set on Friday was wrong", "Friday"),
            ("as a reminder, the release was on Monday", "Monday"),
            ("remind me what happened on Monday", "Monday"),
            ("remind me why we cancelled the call on Tuesday", "Tuesday"),
            ("I always remember to call Anna on Friday", "Friday"),
            ("the note said remind me tomorrow at 9", "tomorrow at 9"),
            ("move the meeting from 3pm to 4pm tomorrow", "from 3pm to 4pm tomorrow"),
            ("die Erinnerung am Montag war falsch", "Montag"),
            ("podsjetnik u petak nije radio", "petak"),
        ] { XCTAssertNil(parse(text, phrase).draft, text) }
    }

    func testOnlyTheCuesSentenceIsScannedAndRangesReferToTheOriginalNote() {
        XCTAssertNil(parse("remind me to call Anna. We met on Friday", "Friday").draft)
        XCTAssertNil(parse("remind me to call Anna\nFriday", "Friday").draft)
        let text = "We met on Monday. Please remind me to call Anna on Friday. Saturday is free."
        let draft = parse(text, "Friday").draft
        XCTAssertEqual(draft?.title, "call Anna")
        XCTAssertEqual(draft.map { String(text[$0.matchedRange]) }, "Friday")
    }

    func testSentenceEndsAfterADateButNotInsideAnOrdinalOrClock() {
        for (text, phrase, title) in [
            ("remind me to pay on November 25. Buy a card", "November 25", "pay"),
            ("podsjeti me na 25. studenog 2027. da platim", "25. studenog 2027.", "platim"),
            ("remind me tomorrow at 9:30. Bring milk", "tomorrow at 9:30", "tomorrow at 9:30"),
        ] { XCTAssertEqual(parse(text, phrase).draft?.title, title, text) }
    }

    func testSupportedEnglishTable() {
        check([
            ("remind me to buy milk tomorrow", "tomorrow", "buy milk", nil),
            ("remember to call today", "today", "call", nil),
            ("don't forget to call tonight", "tonight", "call", nil),
            ("reminder: the day after tomorrow to buy a card", "the day after tomorrow", "buy a card", nil),
            ("remind me to call in 3 days", "in 3 days", "call", nil),
            ("remind me in 2 weeks to call", "in 2 weeks", "call", nil),
            ("remind me on this Friday to call Anna", "this Friday", "call Anna", nil),
            ("remind me to call on November 25", "November 25", "call", nil),
            ("remind me to call on 25 November", "25 November", "call", nil),
            ("remind me to call on 25th of November", "25th of November", "call", nil),
            ("remind me to call on December 1st 2027", "December 1st 2027", "call", nil),
            ("remind me to call on 2027-03-04", "2027-03-04", "call", nil),
            ("remind me to call on 24/7/2027", "24/7/2027", "call", nil),
            ("remind me to call tomorrow at 9:30", "tomorrow at 9:30", "call", 9),
            ("remind me to call on Friday 9am", "Friday 9am", "call", 9),
        ])
    }

    func testSupportedGermanTable() {
        check([
            ("erinnere mich daran Milch heute zu kaufen", "heute", "Milch zu kaufen", nil),
            ("bitte nicht vergessen morgen zu telefonieren", "morgen", "telefonieren", nil),
            ("denk daran heute Abend zu telefonieren", "heute Abend", "telefonieren", nil),
            ("denk dran übermorgen zu telefonieren", "übermorgen", "telefonieren", nil),
            ("Erinnerung: in 3 Tagen an die Blumen", "in 3 Tagen", "die Blumen", nil),
            ("erinnere mich in 2 Wochen an Anna", "in 2 Wochen", "Anna", nil),
            ("erinnere mich an diesen Freitag wegen Anna", "diesen Freitag", "Anna", nil),
            ("erinnere mich am 25. November an Anna", "25. November", "Anna", nil),
            ("erinnere mich am 25. November 2027 an Anna", "25. November 2027", "Anna", nil),
            ("erinnere mich morgen um 9:30 an Anna", "morgen um 9:30", "Anna", 9),
            ("erinnere mich morgen um 9 an Anna", "morgen um 9", "Anna", nil),
        ])
    }

    func testSupportedCroatianTable() {
        check([
            ("podsjeti me da nazovem danas", "danas", "nazovem", nil),
            ("molim nemoj zaboraviti da nazvati sutra", "sutra", "nazvati", nil),
            ("ne zaboravi da nazvati večeras", "večeras", "nazvati", nil),
            ("podsjetnik: prekosutra da kupim čestitku", "prekosutra", "kupim čestitku", nil),
            ("podsjeti me za 3 dana da nazovem", "za 3 dana", "nazovem", nil),
            ("podsjeti me za 2 tjedna da nazovem", "za 2 tjedna", "nazovem", nil),
            ("podsjeti me u ovaj petak da nazovem", "ovaj petak", "nazovem", nil),
            ("podsjeti me u srijedu da nazovem", "srijedu", "nazovem", nil),
            ("podsjeti me na 25. studenog 2027. da nazovem", "25. studenog 2027.", "nazovem", nil),
            ("podsjeti me na 25. studenoga da nazovem", "25. studenoga", "nazovem", nil),
            ("podsjeti me sutra u 9:30 da nazovem", "sutra u 9:30", "nazovem", 9),
            ("podsjeti me sutra u 9 da nazovem", "sutra u 9", "nazovem", nil),
        ])
    }

    private func check(_ rows: [(String, String, String, Int?)], file: StaticString = #filePath, line: UInt = #line) {
        for (text, phrase, title, hour) in rows {
            let minute = phrase == "Friday 9am" ? 0 : 30
            let result = parse(text, phrase, at: minute == 0 ? "2026-11-20 09:00" : "2026-11-20 09:30")
            let calendar = Support.calendar(Support.berlin)
            let expected = NoteDraft(title: title,
                start: DateComponents(calendar: calendar, timeZone: calendar.timeZone, year: 2026, month: 11, day: 20,
                    hour: hour, minute: hour == nil ? nil : minute),
                matchedText: phrase, matchedRange: text.range(of: phrase)!)
            // Whole-value comparison includes unchanged note, title, matched range, zone and optional clock.
            XCTAssertEqual(result, ParsedNote(text: text, draft: expected), text, file: file, line: line)
        }
    }

    func testUnsupportedShapesAndNeighbours() {
        let rows = [
            ("remind me on Monday week", "Monday"), ("remind me a week on Monday", "Monday"),
            ("remind me the Monday after next", "Monday"), ("remind me on the first Monday of December", "Monday"),
            ("remind me on the second Tuesday in December", "Tuesday"),
            ("erinnere mich am übernächsten Freitag", "Freitag"),
            ("erinnere mich am Montag in zwei Wochen", "Montag"),
            ("podsjeti me u petak za tjedan dana", "petak"),
            ("podsjeti me idući ponedjeljak", "ponedjeljak"),
            ("remind me a day before December 24", "December 24"),
            ("remind me one week before December 20", "December 20"),
            ("remind me to call Anna Friday", "Friday"),
            ("remind me on Friday afternoon", "Friday afternoon"),
            ("remind me on Friday the 27th", "Friday"),
            ("remind me tomorrow at 9 30", "tomorrow at 9"),
            ("remind me tomorrow at nine", "tomorrow"),
            ("erinnere mich morgen um neun", "morgen"),
            ("podsjeti me sutra u devet", "sutra"),
            ("remind me on 3/4/2027", "3/4/2027"),
            ("remind me on 24/7", "24/7"), ("remind me at 9am", "9am"),
            ("remind me on Christmas", "Christmas"),
            ("remind me next Monday", "next Monday"),
            ("remind me to move the meeting from 3pm to 4pm tomorrow", "from 3pm to 4pm tomorrow"),
            ("remind me a day before December 24", "a day before December 24"),
            ("remind me one week before December 20", "one week before December 20"),
            ("podsjetnik: sutra u 15 sati zubar", "sutra u 15"),
        ]
        for (text, phrase) in rows { XCTAssertNil(parse(text, phrase).draft, text) }
        for phrase in ["Monday week", "a week on Monday", "the Monday after next", "the first Monday of December", "the second Tuesday in December", "übernächsten Freitag", "Montag in zwei Wochen", "petak za tjedan dana", "idući ponedjeljak", "Friday, November 21", "tomorrow from 3pm to 4pm"] {
            XCTAssertNil(parse("remind me on \(phrase)", phrase).draft, phrase)
        }
        XCTAssertNil(parse("remind me tomorrow", "tomorrow", duration: 3600).draft)
    }

    func testDayWordTaskTextAlsoNeedsAConnector() {
        for text in ["remind me not tomorrow", "remind me a week tomorrow", "remind me two weeks tomorrow", "erinnere mich nicht morgen", "podsjeti me ne sutra"] {
            let phrase = text.hasSuffix("morgen") ? "morgen" : text.hasSuffix("sutra") ? "sutra" : "tomorrow"
            XCTAssertNil(parse(text, phrase).draft, text)
        }
        for text in ["remind me to call tomorrow", "remember to call tomorrow", "reminder: call tomorrow", "remind me tomorrow"] {
            XCTAssertNotNil(parse(text, "tomorrow").draft, text)
        }
    }

    func testTaskConnectorBeforeDatePreposition() {
        for (text, title) in [
            ("don't forget to buy milk on Friday", "buy milk"),
            ("reminder: dentist on Friday", "dentist"),
            ("remind me about the dentist on Friday", "the dentist"),
            ("remind me for the dentist on Friday", "the dentist"),
            ("erinnere mich daran Anna am Friday", "Anna"),
            ("podsjeti me da nazovem u Friday", "nazovem"),
        ] { XCTAssertEqual(parse(text, "Friday").draft?.title, title, text) }
        for text in ["remind me a week on Monday", "don't forget the milk on Monday", "remind me call Anna on Monday"] {
            XCTAssertNil(parse(text, "Monday").draft, text)
        }
    }

    func testPunctuationBeforeTaskConnectorLeavesNoCueFragment() {
        XCTAssertEqual(parse("podsjeti me na 1. prosinca 2027. da platim", "1. prosinca 2027").draft?.title, "platim")
        let timed = parse("podsjeti me na 2. ožujka 2027. u 10:30 da nazovem", "2. ožujka 2027. u 10:30", at: "2027-03-02 10:30").draft
        XCTAssertEqual(timed?.title, "nazovem")
        XCTAssertEqual(timed?.start.hour, 10)
        XCTAssertEqual(timed?.start.minute, 30)
    }

    func testTitlesUseOnlyTheRequestAndLeaveNoFragments() {
        for (text, phrase, title) in [
            ("I need a reminder. Remind me to call Anna tomorrow", "tomorrow", "call Anna"),
            ("remind me on Friday to buy a card", "Friday", "buy a card"),
            ("remind me to call Anna (tomorrow)", "tomorrow", "call Anna"),
            ("remind me tomorrow", "tomorrow", "tomorrow"),
            ("Erinnerung: morgen", "morgen", "morgen"),
            ("remind me to call Anna on Friday", "Friday", "call Anna"),
        ] { XCTAssertEqual(parse(text, phrase).draft?.title, title, text) }
        let text = "remind me to " + String(repeating: "call Anna ", count: 20) + "tomorrow"
        let title = parse(text, "tomorrow").draft?.title
        XCTAssertLessThanOrEqual(title?.count ?? 101, 100)
        XCTAssertEqual(title, String(repeating: "call Anna ", count: 9) + "call…")
    }
}

/// Kept separate so a regression that traps is visible as a failed test process.
final class NoteDateUnicodeTests: XCTestCase {
    func testUnicodeDigitsNeverBecomeParsedIntegers() {
        let calendar = NoteTestSupport.calendar(NoteTestSupport.berlin)
        let reference = NoteTestSupport.date("2026-11-15 21:00", calendar.timeZone)
        for phrase in ["tomorrow at ９", "tomorrow at ９:３０", "２４/７/2027", "tomorrow at ٩", "tomorrow at ९"] {
            let text = "remind me on \(phrase)"
            let scanner = ScriptedDateScanner([.init(phrase: phrase, at: "2027-07-24 09:00")])
            XCTAssertNil(NoteDateParser(scanner: scanner).parse(text, reference: reference, calendar: calendar).draft)
        }
    }
}

final class NoteDateRolloverClockTests: XCTestCase {
    func testClockMinutesAreNotLateMonthDays() {
        for (phrase, at, hour, minute) in [
            ("March 2 at 10:30", "2027-03-02 10:30", 10, 30),
            ("March 1 at 9:30", "2027-03-01 09:30", 9, 30),
            ("December 1 at 9:31", "2026-12-01 09:31", 9, 31),
        ] {
            let calendar = NoteTestSupport.calendar(NoteTestSupport.berlin)
            let scanner = ScriptedDateScanner([.init(phrase: phrase, at: at)])
            let draft = NoteDateParser(scanner: scanner).parse("remind me on " + phrase,
                reference: NoteTestSupport.date("2026-11-15 21:00", calendar.timeZone), calendar: calendar).draft
            XCTAssertEqual(draft?.start.hour, hour, phrase)
            XCTAssertEqual(draft?.start.minute, minute, phrase)
        }
    }
}
