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

    public static let maximumLength = 100

    public var hasOversizedText: Bool {
        Self.exceedsLengthLimit(text)
    }

    public var oversizedAliases: [String] {
        aliases.filter { Self.exceedsLengthLimit($0) }
    }

    public var exceedsLengthLimit: Bool {
        hasOversizedText || !oversizedAliases.isEmpty
    }

    public static func exceedsLengthLimit(_ value: String) -> Bool {
        trimEdgeWhitespace(value).count > maximumLength
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

    public static func normalizeAliases(
        _ aliases: [String],
        matchingText text: String = ""
    ) -> (aliases: [String], droppedSelfMatches: [String]) {
        let termKey = matchKey(text)
        var seenKeys: Set<String> = []
        var seenSelfKeys: Set<String> = []
        var normalized: [String] = []
        var droppedSelf: [String] = []
        for raw in aliases {
            let trimmed = trimEdgeWhitespace(raw)
            guard !trimmed.isEmpty else { continue }
            let key = matchKey(trimmed)
            if !termKey.isEmpty, key == termKey {
                if seenSelfKeys.insert(key).inserted {
                    droppedSelf.append(trimmed)
                }
                continue
            }
            if seenKeys.insert(key).inserted {
                normalized.append(trimmed)
            }
        }
        return (normalized, droppedSelf)
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
    case textTooLong(limit: Int)
    case aliasTooLong(value: String, limit: Int)
    case conflict(value: String, termID: UUID)
    case termNotFound(UUID)

    public var errorDescription: String? {
        switch self {
        case .emptyText:
            return "Term text cannot be blank."
        case .textTooLong(let limit):
            return "Term text must be \(limit) characters or fewer."
        case .aliasTooLong(let value, let limit):
            let preview = value.count > 24 ? String(value.prefix(24)) + "…" : value
            return "Alias \"\(preview)\" must be \(limit) characters or fewer."
        case .conflict(let value, _):
            return "\"\(value)\" is already used by another term or alias."
        case .termNotFound:
            return "This term no longer exists."
        }
    }
}
