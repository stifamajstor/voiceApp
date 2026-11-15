import Foundation

/// Keeps a dictated note unchanged and proposes a draft only when the note contains an explicit reminder cue.
///
/// **Cues.** Case-insensitive whole words or phrases, anywhere in the note, from the single `cuePhrases` table:
/// English "remind me", "reminder", "remember to", "don't forget" (also curly apostrophe), "do not forget";
/// German "erinnere mich", "erinnerung", "nicht vergessen", "denk daran", "denk dran";
/// Croatian "podsjeti me", "podsjetnik", "nemoj zaboraviti", "ne zaboravi". Without one, the scanner is not called.
/// The cue itself is excluded from the negation check. These words request a draft; date mentions alone do not.
///
/// **Kind and time.** A draft is a reminder. Only a digit time span with a trusted start and end makes an event.
/// Meeting, appointment and call words do not change the kind. A clock time is kept only when the phrase states
/// matching digits (`9:30`, `9pm`, `19:00`, or an hour after "at", "from", "to", "until", "till"). The detector
/// moves bare "at 7" to 19:00 and "at 3" to 15:00; these guesses and word times keep only the day (`hour == nil`).
/// A meridiem anywhere in a span can explain its other endpoint ("from 3 to 4pm"). "For an hour" is not read.
///
/// **Consistency.** No draft when unconsumed digits directly follow a hit (optionally after "the", "den", "der"):
/// the detector can truncate "9 30" to 09:00 or "Friday the 27th" to a different Friday. "Next <weekday>" in
/// English, German or Croatian is refused, including when the detector omits the modifier: within three days it
/// can skip the coming weekday. A weekday in a hit must agree with its resolved date; the detector accepts
/// "Friday, November 21" even when the 21st is Saturday. Numeric day/month phrases without a year are refused:
/// "24/7" can mean continuous service. With a year, ambiguous day/month orders ("3/4/2027") are still refused
/// because the detector follows the process region. "February 30" can roll into March; a late day incompatible
/// with the preceding month is refused. Recurrence or negation outside cues is refused (English every/each/not/
/// never/except/since; German jeden/jede/jedes/nicht/kein; Croatian svaki/svake/svakog/ne). Named weekdays such as
/// "Black Friday" are still refused because the detector can mistake the holiday for the coming Friday.
///
/// **Other conservative limits.** No draft for notes over `maximumNoteLength`, no hits, different dates or spans,
/// time-only phrases (the detector guesses today), phrases carrying their own time zone, past dates or times,
/// dates over two years ahead, or non-Gregorian calendars. Equal duplicate hits are allowed if all are usable.
/// A span without digits can be a misread offset ("two weeks from tomorrow"), so it is refused. Times within an
/// hour of a daylight-saving transition lose their clock time, including a span's end. An unexplained midnight
/// is refused because "tomorrow at midnight" can roll into the day after. A part of the day after a hit drops
/// its time because the detector can stop before "in the evening". Spans over a day or with unexplained ends
/// keep only the trusted start. The scanner checks clock skew, equivalent zone rules and midnight boundaries.
///
/// **Inputs and title.** Rules use the supplied `reference` and Gregorian `calendar`. With `SystemDateScanner`,
/// callers must pass the time of parsing (within 60 seconds of the system clock) and the system calendar; the
/// detector cannot take a reference clock, zone or language and reads the user's preferred languages itself.
/// Scripted tests isolate the parser from it. The title removes the hit, its preceding date preposition and all
/// cues with their following connector (to/that/daran/an/da, also about/of). Whitespace and edge punctuation are
/// trimmed, and long titles are cut at a word to `maximumTitleLength` with "…". If empty, the cut note is used.
public struct NoteDateParser: Sendable {
    /// Titles are cut to this many characters.
    public static let maximumTitleLength = 100
    /// Longer notes are not scanned: on this machine, 100,000 characters of repeated "1234567890 " took
    /// 2.6–2.7 seconds in NSDataDetector (three runs, macOS 26.6.2, November 2026).
    public static let maximumNoteLength = 4_000
    private static let horizonInYears = 2

    public let scanner: any DateScanner

    public init(scanner: any DateScanner = SystemDateScanner()) {
        self.scanner = scanner
    }

    /// `reference` is the time of parsing; the system scanner requires it within 60 seconds of its clock.
    public func parse(_ text: String, reference: Date, calendar: Calendar) -> ParsedNote {
        ParsedNote(text: text, draft: draft(for: text, reference: reference, calendar: calendar))
    }

    private static let wallUnits: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute, .second]

    private func draft(for text: String, reference: Date, calendar: Calendar) -> NoteDraft? {
        guard calendar.identifier == .gregorian,
              text.utf16.count <= Self.maximumNoteLength,
              Self.cue.firstMatch(in: text) != nil
        else { return nil }
        let found = scanner.scan(text, reference: reference, timeZone: calendar.timeZone)
        guard let hit = found.first,
              found.allSatisfy({
                  $0.date == hit.date && $0.duration == hit.duration
                      && Self.isUsablePhrase(text[$0.range], $0, calendar: calendar)
                      && Self.trailingDigits.firstMatch(in: String(text[$0.range.upperBound...])) == nil
              }),
              Self.nextWeekday.firstMatch(in: text) == nil,
              Self.recurrenceOrNegation.firstMatch(in: Self.cue.replacing(in: text, with: " ")) == nil
        else { return nil }
        let matchedText = String(text[hit.range])
        let reading = ClockReading(matchedText)

        let wall = calendar.dateComponents(Self.wallUnits, from: hit.date)
        let isTimed = reading.explains(wall)
            && !Self.isNearOffsetChange(hit.date, in: calendar.timeZone)
            && Self.partOfDayAfter.firstMatch(in: String(text[hit.range.upperBound...])) == nil
        // A span with no digits in the phrase is the detector misreading an offset: "two weeks from tomorrow".
        if hit.duration > 0 && !isTimed && !matchedText.contains(where: \.isNumber) { return nil }
        if !isTimed && wall.hour == 0 && wall.minute == 0 && wall.second == 0 { return nil }
        if Self.rolledOver(wall, phrase: matchedText, calendar: calendar) { return nil }

        let isPast = isTimed ? hit.date <= reference : calendar.startOfDay(for: hit.date) < calendar.startOfDay(for: reference)
        if isPast { return nil }
        if let limit = calendar.date(byAdding: .year, value: Self.horizonInYears, to: reference), hit.date > limit { return nil }

        var end: DateComponents?
        if isTimed, reading.tokens.count >= 2, hit.duration > 0, hit.duration <= 86_400 {
            let endDate = hit.date + hit.duration
            let endWall = calendar.dateComponents(Self.wallUnits, from: endDate)
            if reading.explains(endWall) && !Self.isNearOffsetChange(endDate, in: calendar.timeZone) { end = Self.components(endWall, calendar: calendar, withTime: true) }
        }

        return NoteDraft(
            kind: end != nil ? .event : .reminder,
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

    // MARK: Phrases that must not become a draft

    private static let timeWords = Pattern(#"(?<![A-Za-z])(?:at|from|to|until|till|around|by|between|and|am|pm|a\.m\.|p\.m\.|o'clock|uhr)(?![A-Za-z])"#)
    private static let fullNumericDate = Pattern(#"\d{1,4}[./-]\d{1,2}[./-]\d{1,4}"#)
    private static let dayAndMonthOrder = Pattern(#"(?<![\d/.-])(\d{1,2})[/.-](\d{1,2})([/.-]\d{2,4})?(?![\d/.-])(?!\s*[ap]\.?m)"#)
    private static let lateMonthDay = Pattern(#"(?<!\d)(29|30|31)(?!\d)"#)

    private static func isUsablePhrase(_ phrase: Substring, _ scanned: ScannedDate, calendar: Calendar) -> Bool {
        let phrase = String(phrase)
        let weekday = calendar.component(.weekday, from: scanned.date)
        return !scanned.namesTimeZone && !isClockTimeOnly(phrase) && !hasAmbiguousDayAndMonth(phrase)
            && weekdayPatterns.enumerated().allSatisfy { index, pattern in
                index + 1 == weekday || pattern.firstMatch(in: phrase) == nil
            }
    }

    /// "9am", "10:30", "from 3pm to 4pm": a time with no day. The detector would put it today, which is a guess.
    private static func isClockTimeOnly(_ phrase: String) -> Bool {
        guard fullNumericDate.firstMatch(in: phrase) == nil else { return false }
        let letters = timeWords.replacing(in: phrase, with: "")
        return letters.allSatisfy { "0123456789:.-–".contains($0) || $0.isWhitespace }
    }

    /// Without a year, "24/7" may not be a date. With a year, the detector follows the process region, so
    /// "3/4/2027" still has two readings; a number above 12 in one slot is unambiguous.
    private static func hasAmbiguousDayAndMonth(_ phrase: String) -> Bool {
        dayAndMonthOrder.matches(in: phrase).contains { match in
            let first = Int(phrase[match.groups[0]!])!, second = Int(phrase[match.groups[1]!])!
            return match.groups[2] == nil || (first <= 12 && second <= 12 && first != second)
        }
    }

    /// The detector turns "February 30" into March 2. A 29, 30 or 31 in the phrase that is more than the previous
    /// month has days, next to a resolved day of 1 to 3, is that rollover.
    private static func rolledOver(_ wall: DateComponents, phrase: String, calendar: Calendar) -> Bool {
        guard let day = wall.day, day <= 3, let month = wall.month, let year = wall.year,
              let firstOfMonth = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let previous = calendar.date(byAdding: .month, value: -1, to: firstOfMonth),
              let daysBefore = calendar.range(of: .day, in: .month, for: previous)?.count
        else { return false }
        return lateMonthDay.matches(in: phrase).contains { Int(phrase[$0.groups[0]!])! > daysBefore }
    }

    /// The zone's UTC offset differs within an hour either side of `date`: the wall time is where clocks jump, so
    /// it may not exist or may occur twice, and the instant the detector chose is one of two guesses.
    private static func isNearOffsetChange(_ date: Date, in zone: TimeZone) -> Bool {
        zone.secondsFromGMT(for: date - 3600) != zone.secondsFromGMT(for: date + 3600)
    }

    // The detector can stop before a second clock number or an ordinal that contradicts its chosen weekday.
    private static let trailingDigits = Pattern(#"^\s*(?:(?:the|den|der)\s+)?\d"#)
    private static let weekdays = [
        "sunday|sonntag|nedjelja|nedjelju|nedjelje", "monday|montag|ponedjeljak|ponedjeljka",
        "tuesday|dienstag|utorak|utorka", "wednesday|mittwoch|srijeda|srijedu|srijede",
        "thursday|donnerstag|četvrtak|četvrtka", "friday|freitag|petak|petka", "saturday|samstag|subota|subotu|subote",
    ]
    private static let weekdayPatterns = weekdays.map { Pattern(#"\b(?:"# + $0 + #")\b"#) }
    // Within three days, "next Monday" can skip the coming Monday; Croatian can omit "sljedeći" from the hit.
    private static let nextWeekday = Pattern(
        #"\b(?:next|nächste[nmrs]?|sljedeć[iaeui]|sljedećeg)\s+(?:"# + weekdays.joined(separator: "|") + #")\b"#)
    private static let recurrenceOrNegation = Pattern(
        #"\b(?:every|each|not|never|except|since|jeden|jede|jedes|nicht|kein|svaki|svake|svakog|ne)\b|\b(?:black|cyber|good|holy|maundy|easter|ash|super|shrove|palm)\s+(?:"#
            + weekdays.joined(separator: "|") + #")\b"#)
    /// "at 9 in the evening": the detector can stop at "9" and read 09:00.
    private static let partOfDayAfter = Pattern(#"^\s*(?:(?:in|at|this)\s+(?:the\s+)?)?(?:morning|afternoon|evening|night|noon|midnight)\b"#)

    // MARK: Reminder cues

    private static let cuePhrases = [
        "remind me", "reminder", "remember to", "don't forget", "don’t forget", "do not forget",
        "erinnere mich", "erinnerung", "nicht vergessen", "denk daran", "denk dran",
        "podsjeti me", "podsjetnik", "nemoj zaboraviti", "ne zaboravi",
    ]
    private static let cueExpression = #"\b(?:"# + cuePhrases.map {
        $0.components(separatedBy: " ").map(NSRegularExpression.escapedPattern(for:)).joined(separator: #"\s+"#)
    }.joined(separator: "|") + #")\b"#
    private static let cue = Pattern(cueExpression)

    // MARK: Titles

    private static let leadingConnector = Pattern(#"\s*\b(?:on|at|by|for|from|until|till|before|around|due|am|um|u)\s*$"#)
    private static let request = Pattern(#"(?:\bplease\s+)?"# + cueExpression + #"(?:\s+(?:to|that|daran|an|da|about|of)\b)?"#)

    private static func title(of text: String, without range: Range<String.Index>) -> String {
        var before = String(text[..<range.lowerBound])
        if let connector = leadingConnector.firstMatch(in: before) {
            before.removeSubrange(connector)
        }
        var title = tidy(before + " " + text[range.upperBound...])
        title = tidy(request.replacing(in: title, with: " "))
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

    func replacing(in text: String, with template: String) -> String {
        expression.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
}
