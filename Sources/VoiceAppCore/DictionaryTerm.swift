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

public enum DictionaryError: Error, Equatable {
    case emptyText
    case conflict(value: String, termID: UUID)
    case termNotFound(UUID)
}
