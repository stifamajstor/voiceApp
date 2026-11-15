import Foundation

/// A reminder proposed from a note. A proposal only: the app shows `matchedText` so the user
/// can see what was understood, and offers undo.
public struct NoteDraft: Equatable, Sendable {
    public let title: String
    /// Year, month and day, plus hour and minute only when the note gave a clock time that could be read back from
    /// its digits. A date without a time has `hour == nil`; it is not midnight. `calendar` and `timeZone` are set.
    public let start: DateComponents
    /// The phrase read as the date, exactly as written in the note.
    public let matchedText: String
    public let matchedRange: Range<String.Index>

    public init(
        title: String, start: DateComponents,
        matchedText: String, matchedRange: Range<String.Index>
    ) {
        self.title = title
        self.start = start
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
