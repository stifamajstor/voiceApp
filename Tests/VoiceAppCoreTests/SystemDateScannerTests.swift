import Foundation
import VoiceAppCore
import XCTest

/// NSDataDetector has no reference-date parameter: it resolves "tomorrow" against the system clock. These tests
/// therefore start from the real "now" and compute what they expect from it, so they hold on any day and in any
/// machine time zone. Reproducible fixed-date tests live in NoteDateParserTests, which use a scripted scanner.
final class SystemDateScannerTests: XCTestCase {
    private typealias Support = NoteTestSupport
    private let scanner = SystemDateScanner()

    private func phrases(_ text: String, _ localeID: String = "en_US", in timeZone: TimeZone = Support.berlin) throws -> [String] {
        let now = try Support.nowAwayFromMidnight(in: timeZone)
        return scanner.scan(text, reference: now, timeZone: timeZone, locale: Locale(identifier: localeID))
            .map { String(text[$0.range]) }
    }

    func testTomorrowAtNineResolvesInTheRequestedTimeZone() throws {
        for timeZone in [Support.berlin, Support.losAngeles, Support.auckland] {
            let now = try Support.nowAwayFromMidnight(in: timeZone)
            let calendar = Support.calendar(timeZone)
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
            let expected = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow)!
            let text = "Call Anna tomorrow at 9"

            let found = scanner.scan(text, reference: now, timeZone: timeZone, locale: Support.en)

            XCTAssertEqual(found.count, 1, timeZone.identifier)
            XCTAssertEqual(found.first?.date, expected, timeZone.identifier)
            XCTAssertEqual(found.first.map { String(text[$0.range]) }, "tomorrow at 9", timeZone.identifier)
            XCTAssertEqual(found.first?.duration, 0)
            XCTAssertEqual(found.first?.namesTimeZone, false)
        }
    }

    func testTimeSpanCarriesItsDuration() throws {
        let now = try Support.nowAwayFromMidnight(in: Support.berlin)
        let found = scanner.scan("Sync tomorrow from 3pm to 4:30pm", reference: now, timeZone: Support.berlin, locale: Support.en)
        XCTAssertEqual(found.first?.duration, 5400)
    }

    func testExplicitTimeZoneInTheTextIsReported() throws {
        let now = try Support.nowAwayFromMidnight(in: Support.berlin)
        let found = scanner.scan("tomorrow at 9am PST", reference: now, timeZone: Support.berlin, locale: Support.en)
        XCTAssertEqual(found.first?.namesTimeZone, true)
    }

    func testReferenceThatIsNotTheSystemClockYieldsNothing() throws {
        let now = try Support.nowAwayFromMidnight(in: Support.berlin)
        for offset: TimeInterval in [-3600, 3600, 86400 * 30] {
            XCTAssertEqual(scanner.scan("tomorrow at 9", reference: now + offset, timeZone: Support.berlin, locale: Support.en), [],
                "reference \(offset)s away from the system clock")
        }
    }

    func testClockThatDisagreesWithTheReferenceYieldsNothing() {
        let reference = Support.date("2026-11-15 12:00", Support.berlin)
        let skewed = SystemDateScanner(clock: { reference + 120 })
        XCTAssertEqual(skewed.scan("tomorrow at 9", reference: reference, timeZone: Support.berlin, locale: Support.en), [])
    }

    func testDayBoundaryCrossedBetweenReferenceAndScanYieldsNothing() {
        let reference = Support.date("2026-11-15 23:59:59", Support.berlin)
        let afterMidnight = SystemDateScanner(clock: { reference + 2 })
        XCTAssertEqual(afterMidnight.scan("tomorrow at 9", reference: reference, timeZone: Support.berlin, locale: Support.en), [])
    }

    func testClockReadAfterTheScanIsAlsoChecked() {
        let reference = Support.date("2026-11-15 23:59:59", Support.berlin)
        let lock = NSLock()
        nonisolated(unsafe) var reads = 0
        let drifting = SystemDateScanner(clock: {
            lock.lock(); defer { lock.unlock() }
            reads += 1
            return reads == 1 ? reference : reference + 2
        })
        XCTAssertEqual(drifting.scan("tomorrow at 9", reference: reference, timeZone: Support.berlin, locale: Support.en), [])
        XCTAssertEqual(reads, 2)
    }

    func testProcessTimeZoneAndLocaleAreRestoredAfterAScan() throws {
        let now = try Support.nowAwayFromMidnight(in: Support.berlin)
        let zoneBefore = NSTimeZone.default
        let localeBefore = Locale.current.identifier
        let languagesBefore = Locale.preferredLanguages
        _ = scanner.scan("tomorrow at 9", reference: now, timeZone: Support.auckland, locale: Locale(identifier: "hr_HR"))
        XCTAssertEqual(NSTimeZone.default, zoneBefore)
        XCTAssertEqual(Locale.current.identifier, localeBefore)
        XCTAssertEqual(Locale.preferredLanguages, languagesBefore)
    }

    // MARK: Recorded detector behaviour (matched phrase only, so the rows hold on any day)

    func testDigitsAreRecognisedWhereWordsAreNot() throws {
        let rows: [(text: String, phrases: [String])] = [
            ("tomorrow at 9", ["tomorrow at 9"]),
            ("tomorrow at nine", ["tomorrow"]),
            ("tomorrow at 10:30", ["tomorrow at 10:30"]),
            ("tomorrow at ten thirty", ["tomorrow"]),
            ("Friday at 9", ["Friday at 9"]),
            ("Friday at nine", ["Friday"]),
            ("November 25", ["November 25"]),
            ("November twenty-fifth", []),
            ("on the 25th", []),
            ("on the twenty-fifth", []),
            ("in 3 days", ["in 3 days"]),
            ("in three days", []),
            ("in 2 hours", []),
            ("in two hours", []),
            ("tomorrow from 3pm to 4pm", ["tomorrow from 3pm to 4pm"]),
            ("tomorrow from three to four", ["tomorrow"]),
            ("at 10:30", ["10:30"]),
            ("at ten thirty", []),
            ("at nine", []),
            ("twenty-five", []),
        ]
        for row in rows {
            XCTAssertEqual(try phrases(row.text), row.phrases, row.text)
        }
    }

    func testPhrasesTheDetectorDoesNotKnowYieldNothing() throws {
        for text in ["end of the month", "next week", "next month", "on the 13th", "in the morning", "noon", "midnight"] {
            XCTAssertEqual(try phrases(text), [], text)
        }
    }

    func testNumbersThatAreNotDatesYieldNothing() throws {
        for text in ["version 6.1", "version 2.5.1", "call 555 1234", "call 555-1234", "5%", "room 13", "I need 5 apples", "it costs 5.99"] {
            XCTAssertEqual(try phrases(text), [], text)
        }
    }

    func testGermanAndCroatianPhrasingsWithMatchingLocales() throws {
        let rows: [(text: String, locale: String, phrases: [String])] = [
            ("morgen um 9", "de_DE", ["morgen um 9"]),
            ("morgen um neun", "de_DE", ["morgen"]),
            ("nächsten Freitag", "de_DE", ["nächsten Freitag"]),
            ("am Freitag um 9", "de_DE", ["Freitag um 9"]),
            ("übermorgen", "de_DE", ["übermorgen"]),
            ("am 13. November", "de_DE", ["13. November"]),
            ("in zwei Stunden", "de_DE", []),
            ("sutra u 9", "hr_HR", ["sutra u 9"]),
            ("sutra u devet", "hr_HR", ["sutra"]),
            ("u petak", "hr_HR", ["petak"]),
            ("sljedeći petak", "hr_HR", ["petak"]),
            ("prekosutra", "hr_HR", ["prekosutra"]),
            ("13. studenoga", "hr_HR", []),
            ("za dva sata", "hr_HR", []),
            // Croatian read with an English locale: only the clock time is found, with no day.
            ("sutra u 9", "en_US", []),
            ("sutra u 10:30", "en_US", ["10:30"]),
            ("u petak", "en_US", []),
        ]
        for row in rows {
            XCTAssertEqual(try phrases(row.text, row.locale), row.phrases, "\(row.text) [\(row.locale)]")
        }
    }
}
