import Foundation

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
}
