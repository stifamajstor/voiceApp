import Foundation

/// Keeps the note unchanged and proposes a reminder only within this grammar; the detector resolves the day.
///
/// **Cue.** A verb cue opens the note or a sentence (after `. ! ? : ;` or a newline), optionally after one of
/// please/hey/ok/okay/also/and/bitte/und/molim/i. Verb cues: remind me, remember to, don't forget (also ’),
/// do not forget; erinnere mich, nicht vergessen, denk daran/dran; podsjeti me, nemoj zaboraviti, ne zaboravi.
/// Reminder/Erinnerung/podsjetnik must be the first word and followed by `:` or a task connector. A question
/// word immediately after the cue refuses the request. Only the first cue's sentence is scanned.
///
/// **Whole-hit shapes** (case insensitive; Croatian names include their case forms):
/// - English: today, tomorrow, tonight, the day after tomorrow; in N days/weeks; [this] weekday;
///   month day or day [of] month, with optional ordinal suffix and four-digit year.
/// - German: heute, morgen, heute Abend, übermorgen; in N Tag/Tage/Tagen/Woche/Wochen; [diesen/diese/dieses]
///   weekday; month day or day. month, optionally with a four-digit year.
/// - Croatian: danas, sutra, večeras, prekosutra; za N dan/dana/tjedan/tjedna/tjedana; [ovaj/ovu/ove/ovog/ovoga]
///   weekday; month day or day. month, optionally with a four-digit year and final dot.
/// - Numeric: yyyy-mm-dd or a/b/yyyy (also dots or hyphens), with a four-digit year; two different
///   numbers both at most 12 are ambiguous and refused. All numbers are ASCII digits.
/// Each shape may end with one digit clock (`at 9`, `9am`, `um 9:30`, `u 15:00`). A time is retained only if its
/// digits explain the detector's wall clock; an unexplained time or a time near DST keeps just the date.
///
/// **Neighbours.** A hit follows the cue/connector directly, an allowed date preposition (on/by/am/an/u/na),
/// or, for day words and digit day/week offsets, task text without a preposition. Any preceding task text
/// must start with a task connector (including remember to) or follow a noun label's colon.
/// Task connectors: to/for/that/about; an/dass/für/daran/zu/wegen/über; da/za/o. After a hit only the sentence
/// end, punctuation or to/that/about/an/dass/zu/wegen/da/o is accepted. Other words and digits refuse it.
///
/// Spans, time zones, past dates, rollovers, unexplained midnight, dates over two years away, different hits,
/// non-Gregorian calendars and notes over 4,000 UTF-16 units give no draft. Common unsupported phrases include
/// next Friday, Friday after task text without on, in two hours, tomorrow at nine and from 3 to 4pm.
/// The system scanner also requires the real clock, equivalent process-zone rules and preferred languages.
/// Titles use only the cue's sentence, removing cue, connectors and date preposition/hit, capped at 100 characters.
public struct NoteDateParser: Sendable {
    public static let maximumTitleLength = 100
    public static let maximumNoteLength = 4_000
    public let scanner: any DateScanner

    public init(scanner: any DateScanner = SystemDateScanner()) { self.scanner = scanner }

    public func parse(_ text: String, reference: Date, calendar: Calendar) -> ParsedNote {
        ParsedNote(text: text, draft: draft(for: text, reference: reference, calendar: calendar))
    }

    private func draft(for text: String, reference: Date, calendar: Calendar) -> NoteDraft? {
        guard calendar.identifier == .gregorian, text.utf16.count <= Self.maximumNoteLength,
              let cue = Self.cue.matches(in: text).first
        else { return nil }
        let rest = String(text[cue.range.upperBound...])
        guard Self.question.firstMatch(in: rest) == nil else { return nil }
        let end = Self.sentenceEnd.firstMatch(in: rest)?.upperBound ?? rest.endIndex
        let sentence = String(rest[..<end])
        let hits = scanner.scan(sentence, reference: reference, timeZone: calendar.timeZone)
        guard let hit = hits.first else { return nil }
        let connector = Self.connector.firstMatch(in: sentence).flatMap { $0.upperBound <= hit.range.lowerBound ? $0 : nil }
        let bodyStart = connector?.upperBound ?? sentence.startIndex
        let hasTaskConnector = connector != nil || cue.groups[0] != nil
            || Self.rememberTo.firstMatch(in: String(text[cue.range])) != nil
        guard hits.allSatisfy({ $0.date == hit.date && $0.duration == 0 && !$0.namesTimeZone }),
              hits.allSatisfy({ Self.shape(of: String(sentence[$0.range])) != nil
                  && Self.neighbours(in: sentence, hit: $0.range, bodyStart: bodyStart,
                      hasTaskConnector: hasTaskConnector) })
        else { return nil }
        let phrase = String(sentence[hit.range])
        let wall = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: hit.date)
        let timed = ClockReading(phrase).explains(wall)
            && calendar.timeZone.secondsFromGMT(for: hit.date - 3600) == calendar.timeZone.secondsFromGMT(for: hit.date + 3600)
        if !timed && wall.hour == 0 && wall.minute == 0 && wall.second == 0 { return nil }
        if Self.rolledOver(wall, phrase: phrase, calendar: calendar) { return nil }
        if timed ? hit.date <= reference : calendar.startOfDay(for: hit.date) < calendar.startOfDay(for: reference) { return nil }
        if let limit = calendar.date(byAdding: .year, value: 2, to: reference), hit.date > limit { return nil }
        let start = DateComponents(calendar: calendar, timeZone: calendar.timeZone, year: wall.year, month: wall.month,
            day: wall.day, hour: timed ? wall.hour : nil, minute: timed ? wall.minute : nil)
        let offset = text.distance(from: text.startIndex, to: cue.range.upperBound)
        let lower = text.index(text.startIndex, offsetBy: offset + sentence.distance(from: sentence.startIndex, to: hit.range.lowerBound))
        let upper = text.index(lower, offsetBy: sentence.distance(from: hit.range.lowerBound, to: hit.range.upperBound))
        return NoteDraft(title: Self.title(sentence, bodyStart: bodyStart, hit: hit.range, fallback: text),
            start: start, matchedText: phrase, matchedRange: lower..<upper)
    }

    private static let connectors = "to|for|that|about|an|dass|für|daran|zu|wegen|über|da|za|o"
    private static let connector = Pattern(#"^\s*(?::\s*|(?:"# + connectors + #")\b\s*)"#)
    private static let cue = Pattern(
        #"(?:\A|[.!?:;\r\n])\s*(?:(?:(?:please|hey|ok|okay|also|and|bitte|und|molim|i)\s+)?(?:remind\s+me|remember\s+to|don['’]t\s+forget|do\s+not\s+forget|erinnere\s+mich|nicht\s+vergessen|denk\s+(?:daran|dran)|podsjeti\s+me|nemoj\s+zaboraviti|ne\s+zaboravi)\b|(?:reminder|erinnerung|podsjetnik)\b\s*(:|(?:"# + connectors + #")\b))"#)
    private static let rememberTo = Pattern(#"\bremember\s+to$"#)
    private static let question = Pattern(#"^\s*(?:what|why|how|when|where|who|which|whether|if|was|warum|wie|wann|wo|wer|ob|što|zašto|kako|kad|kada|gdje|tko)\b"#)
    // A dot in a numbered day or a colon in a clock belongs to the date, not to the sentence boundary.
    private static let sentenceEnd = Pattern(
        #"(?<![0-9])\.(?!\p{L})|(?<=[0-9])\.(?![0-9]|\s*(?:"#
            + languages.map(\.month).joined(separator: "|") + "|" + connectors + #")\b|\s*(?:at|um|u)\s+[0-9])|[!?;\r\n]|:(?![0-9])"#)
    private static let titleConnector = Pattern(#"^[\s\p{P}]*(?:"# + connectors + #")\b\s*"#)
    private static let preposition = Pattern(#"\b(?:on|by|am|an|u|na)\s*$"#)
    private static let following = Pattern(#"^\s*(?:$|[\p{P}]|(?:to|that|about|an|dass|zu|wegen|da|o)\b)"#)

    private struct Language {
        let day: String
        let offset: String
        let weekday: String
        let month: String
        let clock: String
    }
    private static let languages = [
        Language(day: "today|tomorrow|tonight|the day after tomorrow", offset: "in [0-9]+ (?:days?|weeks?)",
            weekday: "(?:this )?(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday)",
            month: "january|jan|february|feb|march|mar|april|apr|may|june|jun|july|jul|august|aug|september|sep|october|oct|november|nov|december|dec", clock: "at"),
        Language(day: "heute|morgen|heute Abend|übermorgen", offset: "in [0-9]+ (?:Tag|Tage|Tagen|Woche|Wochen)",
            weekday: "(?:(?:diesen|diese|dieses) )?(?:montag|dienstag|mittwoch|donnerstag|freitag|samstag|sonntag)",
            month: "januar|februar|märz|april|mai|juni|juli|august|september|oktober|november|dezember", clock: "um"),
        Language(day: "danas|sutra|večeras|prekosutra", offset: "za [0-9]+ (?:dan|dana|tjedan|tjedna|tjedana)",
            weekday: "(?:(?:ovaj|ovu|ove|ovog|ovoga) )?(?:ponedjeljak|ponedjeljka|utorak|utorka|srijeda|srijedu|srijede|četvrtak|četvrtka|petak|petka|subota|subotu|subote|nedjelja|nedjelju|nedjelje)",
            month: "siječanj|siječnja|veljača|veljače|ožujak|ožujka|travanj|travnja|svibanj|svibnja|lipanj|lipnja|srpanj|srpnja|kolovoz|kolovoza|rujan|rujna|listopad|listopada|studeni|studenog|studenoga|prosinac|prosinca", clock: "u"),
    ]
    private enum DateShape { case relative, fixed }
    private static let clock = #"[0-9]{1,2}(?::[0-9]{2})?(?:\s*[ap]\.?m\.?)?"#
    private static let shapes: [(Pattern, DateShape)] = languages.flatMap { language -> [(Pattern, DateShape)] in
        let time = #"(?:\s+(?:"# + language.clock + #"\s+)?"# + clock + #")?"#
        let month = "(?:" + language.month + ")"
        let day = #"[0-9]{1,2}(?:st|nd|rd|th|\.)?"#
        let date = "(?:" + month + " " + day + "|" + day + " (?:of )?" + month + #")(?:,? [0-9]{4}\.?)?"#
        return [(Pattern("^(?:" + language.day + "|" + language.offset + ")" + time + "$"), .relative),
                (Pattern("^(?:" + language.weekday + "|" + date + ")" + time + "$"), .fixed)]
    }
    private static let numeric = Pattern(#"^(?:[0-9]{4}-[0-9]{2}-[0-9]{2}|([0-9]{1,2})([./-])([0-9]{1,2})\2[0-9]{4})(?:\s+(?:(?:at|um|u)\s+)?"# + clock + #")?$"#)

    private static func shape(of phrase: String) -> DateShape? {
        if let shape = shapes.first(where: { $0.0.firstMatch(in: phrase) != nil }) { return shape.1 }
        guard let match = numeric.matches(in: phrase).first else { return nil }
        if let first = match.groups[0], let second = match.groups[2],
           let a = Int(phrase[first]), let b = Int(phrase[second]), a <= 12 && b <= 12 && a != b { return nil }
        return .fixed
    }

    private static func neighbours(in text: String, hit: Range<String.Index>, bodyStart: String.Index, hasTaskConnector: Bool) -> Bool {
        guard hit.lowerBound >= bodyStart, following.firstMatch(in: String(text[hit.upperBound...])) != nil else { return false }
        let before = String(text[bodyStart..<hit.lowerBound])
        if before.trimmingCharacters(in: .whitespaces).isEmpty { return true }
        if let prep = preposition.firstMatch(in: before) {
            return before[..<prep.lowerBound].trimmingCharacters(in: .whitespaces).isEmpty || hasTaskConnector
        }
        return hasTaskConnector && shape(of: String(text[hit])) == .relative
    }

    private static let lateMonthDay = Pattern(#"(?<![0-9:])(29|30|31)(?![0-9]|:[0-9]{2})"#)
    private static func rolledOver(_ wall: DateComponents, phrase: String, calendar: Calendar) -> Bool {
        guard let day = wall.day, day <= 3, let month = wall.month, let year = wall.year,
              let first = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let previous = calendar.date(byAdding: .month, value: -1, to: first),
              let days = calendar.range(of: .day, in: .month, for: previous)?.count else { return false }
        return lateMonthDay.matches(in: phrase).contains { match in
            match.groups[0].flatMap { Int(phrase[$0]) }.map { $0 > days } ?? false
        }
    }

    private static func title(_ text: String, bodyStart: String.Index, hit: Range<String.Index>, fallback: String) -> String {
        var before = String(text[bodyStart..<hit.lowerBound])
        if let prep = preposition.firstMatch(in: before) { before.removeSubrange(prep) }
        var after = String(text[hit.upperBound...])
        if tidy(before).isEmpty, let connector = titleConnector.firstMatch(in: after) { after.removeSubrange(connector) }
        var title = tidy(before + " " + after)
        if title.isEmpty { title = tidy(String(text[bodyStart...])) }
        if title.isEmpty { title = tidy(fallback) }
        guard title.count > maximumTitleLength else { return title }
        var cut = String(title.prefix(maximumTitleLength - 1))
        if let space = cut.lastIndex(of: " ") { cut = String(cut[..<space]) }
        return tidy(cut) + "…"
    }
    private static func tidy(_ text: String) -> String {
        let emptyBrackets = Pattern(#"\(\s*\)|\[\s*\]|\{\s*\}"#)
        return emptyBrackets.replacing(in: text, with: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }
}

private struct ClockReading {
    private static let number = Pattern(#"(?<![0-9:./-])([0-9]{1,2})(?::([0-9]{2}))?(?:\s*([ap])\.?m\.?(?![A-Za-z]))?(?![0-9:])"#)
    private static let connector = Pattern(#"\bat\s*$"#)
    let phrase: String
    init(_ phrase: String) { self.phrase = phrase }

    func explains(_ wall: DateComponents) -> Bool {
        guard let hour = wall.hour, let minute = wall.minute, wall.second == 0 else { return false }
        return Self.number.matches(in: phrase).contains { match in
            guard let range = match.groups[0], let h = Int(phrase[range]), h < 24 else { return false }
            let m = match.groups[1].flatMap { Int(phrase[$0]) }
            let meridiem = match.groups[2].map { String(phrase[$0]).lowercased() }
            guard m != nil || meridiem != nil || Self.connector.firstMatch(in: String(phrase[..<match.range.lowerBound])) != nil else { return false }
            let statedHour = meridiem.map { h % 12 + ($0 == "p" ? 12 : 0) } ?? h
            return statedHour == hour && (m ?? 0) == minute
        }
    }
}

private struct Pattern {
    struct Match {
        let range: Range<String.Index>
        let groups: [Range<String.Index>?]
    }
    private let expression: NSRegularExpression
    init(_ pattern: String) { expression = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) }
    func matches(in text: String) -> [Match] {
        expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { result in
            guard let range = Range(result.range, in: text) else { return nil }
            return Match(range: range, groups: (1..<result.numberOfRanges).map { Range(result.range(at: $0), in: text) })
        }
    }
    func firstMatch(in text: String) -> Range<String.Index>? { matches(in: text).first?.range }
    func replacing(in text: String, with template: String) -> String {
        expression.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
}
