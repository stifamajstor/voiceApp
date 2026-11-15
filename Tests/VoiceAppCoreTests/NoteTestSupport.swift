import Foundation
import XCTest

enum NoteTestSupport {
    static let berlin = TimeZone(identifier: "Europe/Berlin")!
    static let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
    static let auckland = TimeZone(identifier: "Pacific/Auckland")!
    static let en = Locale(identifier: "en_US")

    static func calendar(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    /// Parses "2026-11-16 09:00" or "2026-11-16 09:00:30" as wall-clock time in `timeZone`.
    static func date(_ text: String, _ timeZone: TimeZone) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = text.count > 16 ? "yyyy-MM-dd HH:mm:ss" : "yyyy-MM-dd HH:mm"
        guard let date = formatter.date(from: text) else { fatalError("bad test date \(text)") }
        return date
    }

    static func utc(_ text: String) -> Date {
        date(text, TimeZone(identifier: "UTC")!)
    }

    /// The real "now", for tests that go through NSDataDetector, which reads the system clock. Skips when "now" is
    /// within five minutes of midnight in `timeZone`, where "tomorrow" is a coin flip.
    static func nowAwayFromMidnight(in timeZone: TimeZone) throws -> Date {
        let now = Date()
        let calendar = calendar(timeZone)
        let midnight = calendar.startOfDay(for: now)
        let nextMidnight = calendar.date(byAdding: .day, value: 1, to: midnight)!
        try XCTSkipIf(now.timeIntervalSince(midnight) < 300 || nextMidnight.timeIntervalSince(now) < 300,
            "Within five minutes of midnight in \(timeZone.identifier)")
        return now
    }
}
