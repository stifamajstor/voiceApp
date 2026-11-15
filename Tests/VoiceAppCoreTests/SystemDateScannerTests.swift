import Foundation
@testable import VoiceAppCore
import XCTest

/// NSDataDetector has no reference-date parameter: it resolves "tomorrow" against the system clock, in the process
/// time zone and the preferred languages. These tests therefore start from the real "now" and compute what they
/// expect from it, so they hold on any day. To see the detector as a user elsewhere would, they switch the process
/// settings with ProcessSettings (test support only) around each scan. Reproducible fixed-date tests live in
/// NoteDateParserTests, which use a scripted scanner.
final class SystemDateScannerTests: ProcessSettingsTestCase {
    private typealias Support = NoteTestSupport
    private let scanner = SystemDateScanner()

    /// The scanner as a user in `timeZone` speaking `localeID` would have it, asked to resolve in that same zone.
    private func scan(_ text: String, at now: Date, in timeZone: TimeZone, speaking localeID: String = "en_US") -> [ScannedDate] {
        ProcessSettings.asUser(in: timeZone, speaking: localeID) {
            scanner.scan(text, reference: now, timeZone: timeZone)
        }
    }

    private func phrases(_ text: String, _ localeID: String = "en_US", in timeZone: TimeZone = Support.berlin) throws -> [String] {
        let now = try Support.nowAwayFromMidnight(in: timeZone)
        return scan(text, at: now, in: timeZone, speaking: localeID).map { String(text[$0.range]) }
    }

    func testTomorrowAtNineResolvesInTheProcessTimeZone() throws {
        for timeZone in [Support.berlin, Support.losAngeles, Support.auckland] {
            let now = try Support.nowAwayFromMidnight(in: timeZone)
            let calendar = Support.calendar(timeZone)
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
            let expected = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow)!
            let text = "Call Anna tomorrow at 9"

            let found = scan(text, at: now, in: timeZone)

            XCTAssertEqual(found.count, 1, timeZone.identifier)
            XCTAssertEqual(found.first?.date, expected, timeZone.identifier)
            XCTAssertEqual(found.first.map { String(text[$0.range]) }, "tomorrow at 9", timeZone.identifier)
            XCTAssertEqual(found.first?.duration, 0)
            XCTAssertEqual(found.first?.namesTimeZone, false)
        }
    }

    func testTimeSpanCarriesItsDuration() throws {
        let now = try Support.nowAwayFromMidnight(in: Support.berlin)
        XCTAssertEqual(scan("Sync tomorrow from 3pm to 4:30pm", at: now, in: Support.berlin).first?.duration, 5400)
    }

    func testExplicitTimeZoneInTheTextIsReported() throws {
        let now = try Support.nowAwayFromMidnight(in: Support.berlin)
        XCTAssertEqual(scan("tomorrow at 9am PST", at: now, in: Support.berlin).first?.namesTimeZone, true)
    }

    func testReferenceThatIsNotTheSystemClockYieldsNothing() throws {
        let now = try Support.nowAwayFromMidnight(in: Support.berlin)
        for offset: TimeInterval in [-3600, 3600, 86400 * 30] {
            XCTAssertEqual(scan("tomorrow at 9", at: now + offset, in: Support.berlin), [], "reference \(offset)s away from the system clock")
        }
    }

    func testClockThatDisagreesWithTheReferenceYieldsNothing() {
        let reference = Support.date("2026-11-15 12:00", Support.berlin)
        let skewed = SystemDateScanner(clock: { reference + 120 }, processTimeZone: { Support.berlin })
        XCTAssertEqual(skewed.scan("tomorrow at 9", reference: reference, timeZone: Support.berlin), [])
    }

    func testDayBoundaryCrossedBetweenReferenceAndScanYieldsNothing() {
        let reference = Support.date("2026-11-15 23:59:59", Support.berlin)
        let afterMidnight = SystemDateScanner(clock: { reference + 2 }, processTimeZone: { Support.berlin })
        XCTAssertEqual(afterMidnight.scan("tomorrow at 9", reference: reference, timeZone: Support.berlin), [])
    }

    func testClockReadAfterTheScanIsAlsoChecked() {
        let reference = Support.date("2026-11-15 23:59:59", Support.berlin)
        let lock = NSLock()
        nonisolated(unsafe) var reads = 0
        let drifting = SystemDateScanner(
            clock: {
                lock.lock(); defer { lock.unlock() }
                reads += 1
                return reads == 1 ? reference : reference + 2
            },
            processTimeZone: { Support.berlin })
        XCTAssertEqual(drifting.scan("tomorrow at 9", reference: reference, timeZone: Support.berlin), [])
        XCTAssertEqual(reads, 2)
    }

    // MARK: The requested time zone must resolve like the process time zone

    private func scanner(processZone: TimeZone, clockReads: Locked<Int>) -> SystemDateScanner {
        let reference = Support.date("2026-11-15 12:00", Support.berlin)
        return SystemDateScanner(clock: { clockReads.increment(); return reference }, processTimeZone: { processZone })
    }

    func testZoneThatIsNotTheProcessZoneYieldsNothingWithoutReadingTheClock() {
        let reference = Support.date("2026-11-15 12:00", Support.berlin)
        let reads = Locked(0)
        let inLosAngeles = scanner(processZone: Support.losAngeles, clockReads: reads)
        XCTAssertEqual(inLosAngeles.scan("tomorrow at 9", reference: reference, timeZone: Support.berlin), [])
        XCTAssertEqual(reads.value, 0)
    }

    func testZonesWithTheSameOffsetsAndRulesAreEquivalent() {
        let reference = Support.date("2026-11-15 12:00", Support.berlin)
        for other in ["Europe/Paris", "Europe/Zurich", "Europe/Berlin"] {
            XCTAssertTrue(SystemDateScanner.resolvesAlike(Support.berlin, TimeZone(identifier: other)!, around: reference), other)
        }
    }

    func testZonesWithTheSameOffsetTodayButDifferentRulesAreNotEquivalent() {
        // Lagos is UTC+1 all year, as Berlin is in November; Berlin moves to UTC+2 in March.
        let lagos = TimeZone(identifier: "Africa/Lagos")!
        let november = Support.date("2026-11-15 12:00", Support.berlin)
        XCTAssertEqual(lagos.secondsFromGMT(for: november), Support.berlin.secondsFromGMT(for: november))
        XCTAssertFalse(SystemDateScanner.resolvesAlike(Support.berlin, lagos, around: november))
        XCTAssertFalse(SystemDateScanner.resolvesAlike(lagos, Support.berlin, around: november))
    }

    func testZonesWithADifferentOffsetAreNotEquivalent() {
        let reference = Support.date("2026-11-15 12:00", Support.berlin)
        XCTAssertFalse(SystemDateScanner.resolvesAlike(Support.berlin, Support.losAngeles, around: reference))
        XCTAssertFalse(SystemDateScanner.resolvesAlike(Support.berlin, TimeZone(identifier: "UTC")!, around: reference))
    }

    func testZonesThatChangeOnDifferentDaysAreNotEquivalent() {
        // Both are UTC-5 in winter and UTC-4 in summer, but the United States and Cuba switch at different moments.
        let newYork = TimeZone(identifier: "America/New_York")!, havana = TimeZone(identifier: "America/Havana")!
        let reference = Support.date("2026-01-15 12:00", newYork)
        XCTAssertEqual(newYork.secondsFromGMT(for: reference), havana.secondsFromGMT(for: reference))
        XCTAssertFalse(SystemDateScanner.resolvesAlike(newYork, havana, around: reference))
    }

    func testEquivalenceHoldsRightAfterATransition() {
        let reference = Support.date("2026-03-29 12:00", Support.berlin)
        XCTAssertTrue(SystemDateScanner.resolvesAlike(Support.berlin, TimeZone(identifier: "Europe/Paris")!, around: reference))
    }

    func testProcessZoneChangingDuringTheScanYieldsNothing() {
        let reference = Support.date("2026-11-15 12:00", Support.berlin)
        let reads = Locked(0)
        let changing = SystemDateScanner(
            clock: { reference },
            processTimeZone: { reads.increment() == 1 ? Support.berlin : Support.losAngeles })
        XCTAssertEqual(changing.scan("tomorrow at 9", reference: reference, timeZone: Support.berlin), [])
        XCTAssertEqual(reads.value, 2)
    }

    func testAnEquivalentRequestedZoneGetsTheProcessResult() throws {
        let paris = TimeZone(identifier: "Europe/Paris")!
        let now = try Support.nowAwayFromMidnight(in: Support.berlin)
        let found = ProcessSettings.asUser(in: Support.berlin) {
            scanner.scan("tomorrow at 9", reference: now, timeZone: paris)
        }
        let calendar = Support.calendar(Support.berlin)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        XCTAssertEqual(found.first?.date, calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow))
    }

    func testARequestedZoneThatIsNotTheProcessZoneYieldsNothingFromTheRealDetector() throws {
        let now = try Support.nowAwayFromMidnight(in: Support.berlin)
        for requested in [Support.losAngeles, Support.auckland, TimeZone(identifier: "Africa/Lagos")!] {
            let found = ProcessSettings.asUser(in: Support.berlin) {
                scanner.scan("tomorrow at 9", reference: now, timeZone: requested)
            }
            XCTAssertEqual(found, [], requested.identifier)
        }
    }

    // MARK: Switching the settings from the tests

    func testSwitchedSettingsAreRestoredAfterTheBody() {
        let before = ProcessSettings.Snapshot.take()
        ProcessSettings.asUser(in: Support.auckland, speaking: "hr_HR") {
            XCTAssertEqual(NSTimeZone.default, Support.auckland)
            XCTAssertEqual(Locale.preferredLanguages, ["hr-HR"])
        }
        XCTAssertEqual(ProcessSettings.Snapshot.take(), before)
    }

    func testSwitchedSettingsAreRestoredWhenTheBodyThrows() {
        struct Failure: Error {}
        let before = ProcessSettings.Snapshot.take()
        XCTAssertThrowsError(try ProcessSettings.asUser(in: Support.auckland, speaking: "de_DE") { throw Failure() })
        XCTAssertEqual(ProcessSettings.Snapshot.take(), before)
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
