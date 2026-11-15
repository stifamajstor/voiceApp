import Foundation
import GRDB

public enum RecordKind: String, Codable, Sendable {
    case dictation
    case note
    case prompt
}

public struct MemoryRecord: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let deviceID: UUID
    public let kind: RecordKind
    public let createdAt: Date
    public let rawText: String
    public let finalText: String
    public let appBundleID: String?
    public let appName: String?
    public let project: String?
    public let modelID: String?
    public let durationSeconds: Double?
    public let audioPath: String?
    public let deletedAt: Date?
}

extension MemoryRecord: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "records"

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

public struct RecordTombstone: Equatable, Sendable {
    public let id: UUID
    public let deviceID: UUID
    public let deletedAt: Date
}
