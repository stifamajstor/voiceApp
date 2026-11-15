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
/// with scripted results, since the system detector cannot be given a clock.
public protocol DateScanner: Sendable {
    /// Relative phrases ("tomorrow") resolve against `reference` in `timeZone`; `locale` selects the language.
    /// A scanner that cannot honour the reference returns no results rather than a guess.
    func scan(_ text: String, reference: Date, timeZone: TimeZone, locale: Locale) -> [ScannedDate]
}

/// Scans with Foundation's `NSDataDetector`.
///
/// The detector has no reference-date parameter: it resolves "tomorrow" or "Friday" against the system clock.
/// It also reads the time zone and language from process-wide settings. So that results do not depend on the
/// machine, `scan` does two things under a lock:
/// - It sets the process time zone and the `AppleLanguages` argument-domain default to the given zone and locale
///   for the length of the scan, then restores them. Code on other threads that reads them during that window
///   sees the scan's values.
/// - It reads the system clock before and after the scan and returns nothing unless both readings are within
///   `maximumClockSkew` of `reference` and on the same calendar day in `timeZone`. A reference that is not "now",
///   or a scan that straddles midnight, would otherwise resolve "tomorrow" to the wrong day.
///
/// Callers therefore pass the current time as `reference`; the `clock` parameter exists only so the agreement
/// check can be tested, and must read the system clock in production.
///
/// The region is not switched: Foundation caches the process locale on first use, so the day/month order of
/// numeric dates ("3/4/2027") follows the process region whatever `locale` says. `NoteDateParser` refuses those.
public struct SystemDateScanner: DateScanner {
    public static let maximumClockSkew: TimeInterval = 60

    private static let processSettings = NSLock()
    private let clock: @Sendable () -> Date

    public init(clock: @escaping @Sendable () -> Date = { Date() }) {
        self.clock = clock
    }

    public func scan(_ text: String, reference: Date, timeZone: TimeZone, locale: Locale) -> [ScannedDate] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        func agreesWithReference(_ now: Date) -> Bool {
            abs(now.timeIntervalSince(reference)) <= Self.maximumClockSkew && calendar.isDate(now, inSameDayAs: reference)
        }

        Self.processSettings.lock()
        defer { Self.processSettings.unlock() }
        let defaults = UserDefaults.standard
        let previousZone = NSTimeZone.default
        let previousArguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var arguments = previousArguments
        arguments["AppleLanguages"] = [locale.identifier(.bcp47)]
        NSTimeZone.default = timeZone
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        defer {
            NSTimeZone.default = previousZone
            defaults.setVolatileDomain(previousArguments, forName: UserDefaults.argumentDomain)
        }

        guard agreesWithReference(clock()),
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
        else { return [] }
        let matches = detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard agreesWithReference(clock()) else { return [] }

        return matches.compactMap { match in
            guard let date = match.date, let range = Range(match.range, in: text) else { return nil }
            return ScannedDate(range: range, date: date, duration: match.duration, namesTimeZone: match.timeZone != nil)
        }
    }
}
