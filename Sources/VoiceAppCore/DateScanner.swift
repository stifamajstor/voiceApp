import Foundation

/// A date phrase found in a note, with the moment the scanner resolved it to.
public struct ScannedDate: Equatable, Sendable {
    /// Where the phrase sits in the scanned text.
    public let range: Range<String.Index>
    public let date: Date
    /// Length of a time span the phrase names ("from 3pm to 4pm"); 0 when it names none.
    public let duration: TimeInterval
    /// True when the phrase carries its own time zone ("9am PST"), so `date` is not a wall-clock time in the caller's zone.
    public let namesTimeZone: Bool

    public init(range: Range<String.Index>, date: Date, duration: TimeInterval = 0, namesTimeZone: Bool = false) {
        self.range = range
        self.date = date
        self.duration = duration
        self.namesTimeZone = namesTimeZone
    }
}

/// Finds date phrases in text and resolves them against a reference date. A seam so the note rules can be tested
/// with scripted results, since the system detector cannot be given a clock or a time zone.
public protocol DateScanner: Sendable {
    /// Relative phrases ("tomorrow") resolve against `reference` in `timeZone`. A scanner that cannot honour the
    /// reference or the zone returns no results rather than a guess.
    func scan(_ text: String, reference: Date, timeZone: TimeZone) -> [ScannedDate]
}

/// Scans with Foundation's `NSDataDetector`, which it uses as the system has it set up and changes nothing.
///
/// The detector has no reference-date, time-zone or language parameter. It resolves "tomorrow" or "Friday" against
/// the system clock, in the process time zone (`NSTimeZone.default`), and reads the phrases of the user's preferred
/// languages. The scanner neither sets nor overrides any of that: no process-wide state is written, so nothing a
/// scan does is visible to other threads. Instead it returns nothing when the caller's assumptions do not hold:
/// - `timeZone` must resolve like the process time zone around `reference`: the same UTC offset at the start and
///   the end of the window from two days before `reference` to two years after it, and the same daylight-saving
///   changes within it (same instants, same offsets afterwards). Two zones with the same offset today but different
///   rules, such as Berlin and Lagos in winter, are not equivalent; Berlin and Paris are. Only offsets are compared,
///   since only they affect which instant a phrase resolves to.
/// - The system clock must be within `maximumClockSkew` of `reference` and on the same calendar day in `timeZone`.
///   A reference that is not "now", or a scan that straddles midnight, would otherwise resolve "tomorrow" to the
///   wrong day. The clock and the zone check are repeated after the scan.
///
/// Callers therefore pass the current time as `reference` and the system's own calendar. The process time zone is
/// read when the app starts, so a change of the system zone while the app runs makes the scanner refuse until the
/// process zone is reset. The `clock` and `processTimeZone` parameters exist only so these checks can be tested and
/// must read the system in production.
///
/// The detector reads all preferred languages, so phrases in any of them can match, and the region is the process
/// region: the day/month order of numeric dates ("3/4/2027") follows it. `NoteDateParser` refuses those.
public struct SystemDateScanner: DateScanner {
    public static let maximumClockSkew: TimeInterval = 60
    private static let windowBefore: TimeInterval = 2 * 86_400
    private static let windowAfter: TimeInterval = 2 * 366 * 86_400

    private let clock: @Sendable () -> Date
    private let processTimeZone: @Sendable () -> TimeZone

    public init(
        clock: @escaping @Sendable () -> Date = { Date() },
        processTimeZone: @escaping @Sendable () -> TimeZone = { NSTimeZone.default }
    ) {
        self.clock = clock
        self.processTimeZone = processTimeZone
    }

    public func scan(_ text: String, reference: Date, timeZone: TimeZone) -> [ScannedDate] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        func agreesWithReference() -> Bool {
            guard Self.resolvesAlike(timeZone, processTimeZone(), around: reference) else { return false }
            let now = clock()
            return abs(now.timeIntervalSince(reference)) <= Self.maximumClockSkew && calendar.isDate(now, inSameDayAs: reference)
        }

        guard agreesWithReference(),
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
        else { return [] }
        let matches = detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard agreesWithReference() else { return [] }

        return matches.compactMap { match in
            guard let date = match.date, let range = Range(match.range, in: text) else { return nil }
            return ScannedDate(range: range, date: date, duration: match.duration, namesTimeZone: match.timeZone != nil)
        }
    }

    /// True if both zones have the same UTC offset at each end of the window around `reference` and the same
    /// daylight-saving transitions inside it, each followed by the same offset.
    static func resolvesAlike(_ first: TimeZone, _ second: TimeZone, around reference: Date) -> Bool {
        let start = reference - windowBefore, end = reference + windowAfter
        guard first.secondsFromGMT(for: start) == second.secondsFromGMT(for: start),
              first.secondsFromGMT(for: end) == second.secondsFromGMT(for: end)
        else { return false }
        func transition(_ zone: TimeZone, after date: Date) -> Date? {
            zone.nextDaylightSavingTimeTransition(after: date).flatMap { $0 <= end ? $0 : nil }
        }
        var cursor = start
        for _ in 0..<32 {
            let next = transition(first, after: cursor)
            guard next == transition(second, after: cursor) else { return false }
            guard let next else { return true }
            guard first.secondsFromGMT(for: next) == second.secondsFromGMT(for: next) else { return false }
            cursor = next
        }
        return false
    }
}
