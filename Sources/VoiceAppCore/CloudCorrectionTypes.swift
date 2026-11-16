import Foundation

public enum CloudProviderID: String, CaseIterable, Codable, Identifiable, Sendable {
    case anthropic
    case openAI = "openai"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .openAI: return "OpenAI"
        }
    }

    public var defaultModelID: String {
        switch self {
        case .anthropic: return "claude-haiku-5-5"
        case .openAI: return "gpt-6-luna"
        }
    }

    public var defaultModelDisplayName: String {
        switch self {
        case .anthropic: return "Claude Haiku 5.5"
        case .openAI: return "GPT-6 Luna"
        }
    }

    public var defaultModelOption: CloudModelOption {
        CloudModelOption(id: defaultModelID, displayName: defaultModelDisplayName)
    }

    public var privacyNotice: String {
        switch self {
        case .anthropic:
            return "Transcripts are sent to Anthropic when correction is on. Prompts and outputs are not retained by default or used for training, though flagged content may be retained."
        case .openAI:
            return "Transcripts are sent to OpenAI when correction is on (store: false). Prompts are not used for training, though abuse-monitoring logs may be retained up to 30 days."
        }
    }
}

public struct CloudModelOption: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let displayName: String

    public init(id: String, displayName: String? = nil) {
        self.id = id
        self.displayName = displayName ?? id
    }
}

public struct CorrectionEdit: Codable, Equatable, Sendable {
    public let original: String
    public let replacement: String

    public init(original: String, replacement: String) {
        self.original = original
        self.replacement = replacement
    }
}

public struct CorrectionPromptContext: Equatable, Sendable {
    public let text: String
    public let dictionaryTerms: [String]
    public let appName: String?

    public init(text: String, dictionaryTerms: [String], appName: String?) {
        self.text = text
        self.dictionaryTerms = dictionaryTerms
        self.appName = appName
    }
}

public enum CorrectionStatus: String, Codable, Equatable, Sendable {
    case applied
    case unchanged
    case fallback
    case skipped
}

public struct CorrectionOutcome: Equatable, Sendable {
    public let inputText: String?
    public let outputText: String
    public let provider: CloudProviderID?
    public let modelID: String?
    public let status: CorrectionStatus?
    public let reason: String?
    public let edits: [CorrectionEdit]

    public init(
        inputText: String? = nil,
        outputText: String,
        provider: CloudProviderID? = nil,
        modelID: String? = nil,
        status: CorrectionStatus? = nil,
        reason: String? = nil,
        edits: [CorrectionEdit] = []
    ) {
        self.inputText = inputText
        self.outputText = outputText
        self.provider = provider
        self.modelID = modelID
        self.status = status
        self.reason = reason
        self.edits = edits
    }
}

public enum CloudCorrectionConfig {
    /// Whole-request wall-clock deadline before pasting the dictionary-corrected fallback.
    public static let requestDeadline: Duration = .seconds(2)
    public static let circuitBreakerFailureThreshold = 3
    public static let circuitBreakerCooldown: Duration = .seconds(300)
    public static let maxWordChangeRatio = 0.40
    public static let maxOutputTokens = 400
    public static let maxPromptDictionaryTerms = 200
    public static let anthropicAPIVersion = "2026-10-21"
    public static let openAIAllowlistedModelIDs = [
        "gpt-6-luna",
        "gpt-6.1-terra",
        "gpt-6-sol",
    ]
}

public enum CloudCorrectionError: Error, Equatable, LocalizedError, Sendable {
    case missingAPIKey(CloudProviderID)
    case timedOut(Duration)
    case networkFailure(String)
    case invalidAPIKey(CloudProviderID)
    case rateLimited(CloudProviderID)
    case modelUnavailable(String)
    case httpError(statusCode: Int, message: String)
    case invalidResponse(String)
    case refused(String?)
    case invalidEdits(EditValidationError)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider):
            return "Add an \(provider.displayName) API key first."
        case .timedOut(let duration):
            let seconds = Double(duration.components.seconds)
                + Double(duration.components.attoseconds) / 1e18
            return String(format: "Timed out after %.1f s.", seconds)
        case .networkFailure(let message):
            return "Network error: \(message)"
        case .invalidAPIKey(let provider):
            return "\(provider.displayName) rejected the API key."
        case .rateLimited(let provider):
            return "\(provider.displayName) rate limit reached."
        case .modelUnavailable(let modelID):
            return "Model \"\(modelID)\" is unavailable."
        case .httpError(let statusCode, let message):
            return message.isEmpty ? "Request failed (HTTP \(statusCode))." : "\(message) (HTTP \(statusCode))."
        case .invalidResponse(let detail):
            return "Unexpected response: \(detail)"
        case .refused(let reason):
            if let reason, !reason.isEmpty {
                return "Model refused the request: \(reason)"
            }
            return "Model refused the request."
        case .invalidEdits(let error):
            return error.errorDescription
        }
    }
}

public enum EditValidationError: Error, Equatable, LocalizedError, Sendable {
    case emptyOriginal
    case originalNotFound(String)
    case ambiguousMatch(String)
    case overlappingEdits
    case excessiveChanges(changedWords: Int, totalWords: Int, maxAllowed: Int)

    public var errorDescription: String? {
        switch self {
        case .emptyOriginal:
            return "Edit original text was empty."
        case .originalNotFound:
            return "An edit did not match the transcript."
        case .ambiguousMatch:
            return "An edit matched multiple places in the transcript."
        case .overlappingEdits:
            return "Edits overlapped."
        case .excessiveChanges(let changedWords, let totalWords, let maxAllowed):
            return "Edits changed too many words (\(changedWords) of \(totalWords), max \(maxAllowed))."
        }
    }
}
