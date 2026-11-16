import Foundation
import GRDB

public struct DictionaryTerm: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var text: String
    public var aliases: [String]
    public var updatedAt: Date
    public var deviceID: UUID
    public var deletedAt: Date?

    public init(id: UUID = UUID(), text: String, aliases: [String] = [], updatedAt: Date = .now,
                deviceID: UUID, deletedAt: Date? = nil) {
        self.id = id
        self.text = text
        self.aliases = aliases
        self.updatedAt = Date(timeIntervalSince1970: updatedAt.timeIntervalSince1970)
        self.deviceID = deviceID
        self.deletedAt = deletedAt
    }

    static func trimEdgeWhitespace(_ value: String) -> String {
        var scalars = Substring.UnicodeScalarView(value.unicodeScalars)
        while let first = scalars.first, first.properties.isWhitespace {
            scalars.removeFirst()
        }
        while let last = scalars.last, last.properties.isWhitespace {
            scalars.removeLast()
        }
        return String(scalars)
    }

    static func matchKey(_ value: String) -> String {
        value.unicodeScalars.split(whereSeparator: { $0.properties.isWhitespace })
            .map { String(String.UnicodeScalarView($0)) }.joined(separator: " ")
            .folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
    }
}

extension DictionaryTerm: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "dictionaryTerms"

    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        .timeIntervalSince1970
    }

    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        .timeIntervalSince1970
    }

    public static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy {
        .uppercaseString
    }
}

public enum DictionaryError: Error, Equatable, LocalizedError {
    case emptyText
    case conflict(value: String, termID: UUID)
    case termNotFound(UUID)

    public var errorDescription: String? {
        switch self {
        case .emptyText:
            return "Term text cannot be blank."
        case .conflict(let value, _):
            return "\"\(value)\" is already used by another term or alias."
        case .termNotFound:
            return "This term no longer exists."
        }
    }
}
