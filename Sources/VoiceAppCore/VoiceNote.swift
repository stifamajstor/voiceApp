import Foundation

public struct VoiceNote: Identifiable, Equatable, Sendable {
    public var id: UUID { record.id }
    public let record: MemoryRecord
    public let text: String
    public let isDone: Bool
    public let reminderDate: Date?
    public let reminderNotifiedAt: Date?

    public func isOverdue(at date: Date) -> Bool {
        !isDone && reminderDate.map { $0 <= date } == true
    }
}

public enum CaptureTrigger: Sendable {
    case pushToTalk, toggle, notePushToTalk, noteToggle

    public var destination: CaptureDestination {
        switch self {
        case .pushToTalk, .toggle: return .dictation
        case .notePushToTalk, .noteToggle: return .note
        }
    }
}

public enum CaptureDestination: Sendable {
    case dictation, note
}

public enum NoteError: LocalizedError {
    case notFound, emptyText

    public var errorDescription: String? {
        switch self {
        case .notFound: return "This note no longer exists. Refresh Notes and try again."
        case .emptyText: return "A note cannot be empty."
        }
    }
}
