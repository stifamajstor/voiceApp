import Foundation

/// A reminder or calendar event proposed from a note. A proposal only: the app shows `matchedText` so the user
/// can see what was understood, and offers undo.
public struct NoteDraft: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case reminder
        case event
    }

    public let kind: Kind
    public let title: String
    /// Year, month and day, plus hour and minute only when the note gave a clock time that could be read back from
    /// its digits. A date without a time has `hour == nil`; it is not midnight. `calendar` and `timeZone` are set.
    public let start: DateComponents
    /// Same units as `start`. Only events have one, and only when the note named a time span.
    public let end: DateComponents?
    /// The phrase read as the date, exactly as written in the note.
    public let matchedText: String
    public let matchedRange: Range<String.Index>

    public init(
        kind: Kind, title: String, start: DateComponents, end: DateComponents? = nil,
        matchedText: String, matchedRange: Range<String.Index>
    ) {
        self.kind = kind
        self.title = title
        self.start = start
        self.end = end
        self.matchedText = matchedText
        self.matchedRange = matchedRange
    }
}

public struct ParsedNote: Equatable, Sendable {
    /// The note exactly as given.
    public let text: String
    public let draft: NoteDraft?

    public init(text: String, draft: NoteDraft?) {
        self.text = text
        self.draft = draft
    }
}
