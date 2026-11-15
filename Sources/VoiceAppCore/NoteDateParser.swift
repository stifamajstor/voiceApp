import Foundation

/// Turns a dictated note into an optional reminder or calendar draft.
///
/// Dates come from a `DateScanner` (by default `NSDataDetector`). The parser's job is to distrust it: a draft with
/// a wrong date is worse than no draft, so anything unclear yields `draft == nil`. The rules:
///
/// - **Reminder or event.** A date makes a reminder. An event needs a clock time as well, plus either a time span
///   in the phrase ("from 3pm to 4pm") or the note naming a meeting, appointment or "call with" someone. "Call mom
///   tomorrow at 6pm" is a reminder. A phrase like "for an hour" is not read: the detector ignores it.
/// - **Times.** A clock time is kept only if the matched phrase says it in digits: `9:30`, `9pm`, `19:00`, or a
///   bare number after "at"/"from"/"to"/"until"/"till" (`at 9`) that equals the resolved hour. The detector moves
///   a bare "at 7" to 19:00 and "at 3" to 15:00; those, and words such as "nine", "noon" or "tonight", leave a
///   date without a time. An unreadable time that resolved to exactly midnight means the detector rolled the day
///   over ("tomorrow at midnight"), so there is no draft. Times within an hour of a daylight-saving change in the
///   calendar's zone are dropped, because the wall time may not exist or may occur twice.
public struct NoteDateParser: Sendable {
    public static let maximumTitleLength = 100

    public let scanner: any DateScanner

    public init(scanner: any DateScanner = SystemDateScanner()) {
        self.scanner = scanner
    }

    public func parse(_ text: String, reference: Date, calendar: Calendar, locale: Locale) -> ParsedNote {
        ParsedNote(text: text, draft: draft(for: text, reference: reference, calendar: calendar, locale: locale))
    }

    private static let wallUnits: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute, .second]

    private func draft(for text: String, reference: Date, calendar: Calendar, locale: Locale) -> NoteDraft? {
        let found = scanner.scan(text, reference: reference, timeZone: calendar.timeZone, locale: locale)
        guard found.count == 1, let hit = found.first else { return nil }
        let matchedText = String(text[hit.range])
        let reading = ClockReading(matchedText)

        let wall = calendar.dateComponents(Self.wallUnits, from: hit.date)
        let isTimed = reading.explains(wall)
        if !isTimed && wall.hour == 0 && wall.minute == 0 && wall.second == 0 { return nil }

        var end: DateComponents?
        if isTimed, hit.duration > 0, hit.duration <= 86_400 {
            let endWall = calendar.dateComponents(Self.wallUnits, from: hit.date + hit.duration)
            if reading.explains(endWall) { end = Self.components(endWall, calendar: calendar, withTime: true) }
        }

        let isEvent = end != nil || (isTimed && Self.namesMeeting.firstMatch(in: text) != nil)
        return NoteDraft(
            kind: isEvent ? .event : .reminder,
            title: Self.title(of: text, without: hit.range),
            start: Self.components(wall, calendar: calendar, withTime: isTimed),
            end: end,
            matchedText: matchedText,
            matchedRange: hit.range)
    }

    private static func components(_ wall: DateComponents, calendar: Calendar, withTime: Bool) -> DateComponents {
        DateComponents(
            calendar: calendar, timeZone: calendar.timeZone, year: wall.year, month: wall.month, day: wall.day,
            hour: withTime ? wall.hour : nil, minute: withTime ? wall.minute : nil)
    }

    // MARK: Event keywords

    private static let namesMeeting = Pattern(#"\b(?:meetings?|appointments?|call with|conference call|video call|phone call)\b"#)

    // MARK: Titles

    private static let leadingConnector = Pattern(#"\s*\b(?:on|at|by|for|from|until|till|before|around|due)\s*$"#)
    private static let requestPrefix = Pattern(#"^(?:please\s+)?remind\s+me(?:\s+(?:to|about|that|of))?\s*"#)

    /// The note without the date phrase and the preposition in front of it, whitespace collapsed, a leading
    /// "remind me to" and surrounding punctuation dropped, cut to `maximumTitleLength`. If nothing is left the
    /// note itself, cut the same way, so the title is never empty.
    private static func title(of text: String, without range: Range<String.Index>) -> String {
        var before = String(text[..<range.lowerBound])
        if let connector = leadingConnector.firstMatch(in: before) {
            before.removeSubrange(connector)
        }
        var title = tidy(before + " " + text[range.upperBound...])
        if let prefix = requestPrefix.firstMatch(in: title) {
            title = tidy(String(title[prefix.upperBound...]))
        }
        if title.isEmpty { title = tidy(text) }
        return truncated(title)
    }

    private static func tidy(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ",.;:-–— "))
    }

    private static func truncated(_ title: String) -> String {
        guard title.count > maximumTitleLength else { return title }
        var cut = String(title.prefix(maximumTitleLength - 1))
        if let space = cut.lastIndex(of: " ") { cut = String(cut[..<space]) }
        return cut.trimmingCharacters(in: CharacterSet(charactersIn: ",.;:-–— ")) + "…"
    }
}

/// The clock times a phrase states in digits, used to check what the detector resolved.
private struct ClockReading {
    struct Token {
        var hour: Int
        var minute: Int
        var hasMeridiem: Bool
    }

    private static let number = Pattern(#"(?<![\d:./-])(\d{1,2})(?::(\d{2}))?(?:\s*([ap])\.?m\.?(?![A-Za-z]))?(?![\d:])"#, caseInsensitive: true)
    private static let connectorBefore = Pattern(#"\b(?:at|from|to|until|till)\s*$"#, caseInsensitive: true)

    let tokens: [Token]
    let hasMeridiem: Bool

    init(_ phrase: String) {
        var tokens: [Token] = []
        var hasMeridiem = false
        for match in Self.number.matches(in: phrase) {
            let hour = Int(phrase[match.groups[0]!])!
            let minute = match.groups[1].map { Int(phrase[$0])! }
            let meridiem = match.groups[2] != nil
            let isTime = minute != nil || meridiem || Self.connectorBefore.firstMatch(in: String(phrase[..<match.range.lowerBound])) != nil
            guard isTime, hour < 24 else { continue }
            hasMeridiem = hasMeridiem || meridiem
            tokens.append(Token(hour: hour, minute: minute ?? 0, hasMeridiem: meridiem))
        }
        self.tokens = tokens
        self.hasMeridiem = hasMeridiem
    }

    /// True if some stated time is the resolved hour and minute, with no seconds. A stated 3 reads as 15:00 only
    /// when an am/pm appears somewhere in the phrase ("from 3 to 4pm").
    func explains(_ wall: DateComponents) -> Bool {
        guard let hour = wall.hour, let minute = wall.minute, wall.second == 0 else { return false }
        return tokens.contains { token in
            token.minute == minute && (token.hour == hour || (hasMeridiem && token.hour % 12 == hour % 12))
        }
    }
}

/// A compiled regular expression over Swift strings.
private struct Pattern {
    struct Match {
        let range: Range<String.Index>
        let groups: [Range<String.Index>?]
    }

    private let expression: NSRegularExpression

    init(_ pattern: String, caseInsensitive: Bool = true) {
        expression = try! NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
    }

    func matches(in text: String) -> [Match] {
        expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { result in
            Match(
                range: Range(result.range, in: text)!,
                groups: (1..<result.numberOfRanges).map { Range(result.range(at: $0), in: text) })
        }
    }

    func firstMatch(in text: String) -> Range<String.Index>? {
        matches(in: text).first?.range
    }
}
