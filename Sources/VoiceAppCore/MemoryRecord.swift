import Foundation
import GRDB

public struct RecordKind: RawRepresentable, Codable, Hashable, Sendable, DatabaseValueConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let dictation = RecordKind(rawValue: "dictation")
    public static let note = RecordKind(rawValue: "note")
    public static let prompt = RecordKind(rawValue: "prompt")
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
    public let correctionInputText: String?
    public let correctionProvider: String?
    public let correctionModel: String?
    public let correctionStatus: String?
    public let correctionReason: String?

    public init(
        id: UUID,
        deviceID: UUID,
        kind: RecordKind,
        createdAt: Date,
        rawText: String,
        finalText: String,
        appBundleID: String?,
        appName: String?,
        project: String?,
        modelID: String?,
        durationSeconds: Double?,
        audioPath: String?,
        deletedAt: Date?,
        correctionInputText: String? = nil,
        correctionProvider: String? = nil,
        correctionModel: String? = nil,
        correctionStatus: String? = nil,
        correctionReason: String? = nil
    ) {
        self.id = id
        self.deviceID = deviceID
        self.kind = kind
        self.createdAt = createdAt
        self.rawText = rawText
        self.finalText = finalText
        self.appBundleID = appBundleID
        self.appName = appName
        self.project = project
        self.modelID = modelID
        self.durationSeconds = durationSeconds
        self.audioPath = audioPath
        self.deletedAt = deletedAt
        self.correctionInputText = correctionInputText
        self.correctionProvider = correctionProvider
        self.correctionModel = correctionModel
        self.correctionStatus = correctionStatus
        self.correctionReason = correctionReason
    }
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
