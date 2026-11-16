import Foundation

public protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

public struct URLSessionHTTPTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = URLSessionHTTPTransport.makeEphemeralSession()) {
        self.session = session
    }

    public static func makeEphemeralSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        return URLSession(configuration: config)
    }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

public protocol CloudCorrectionProvider: Sendable {
    var id: CloudProviderID { get }
    func correct(_ context: CorrectionPromptContext, modelID: String, apiKey: String) async throws -> [CorrectionEdit]
    func listModels(apiKey: String) async throws -> [CloudModelOption]
}

// MARK: - Prompt & Schema

enum CorrectionPromptBuilder {
    static let systemPrompt = """
    You fix speech-to-text transcription errors in dictated text.
    Only fix clear transcription mistakes (homophones, misheard words, broken proper nouns, or wrong capitalization/punctuation of terms) using the sentence context, the user's dictionary terms, and the target app name.
    Preserve the speaker's language, phrasing, tone, and wording. Do not paraphrase, translate, summarize, or reword.
    Return only minimal targeted edits in JSON matching the schema. Each `original` must be an exact, unique substring of the transcript; if a word appears more than once, include an adjacent word so `original` matches only the intended span. If no edits are needed, return an empty `edits` array.
    """

    static func userPrompt(for context: CorrectionPromptContext) -> String {
        var sections: [String] = []
        if let appName = context.appName?.trimmingCharacters(in: .whitespacesAndNewlines), !appName.isEmpty {
            sections.append("Target app: \(appName)")
        }
        let terms = context.dictionaryTerms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(CloudCorrectionConfig.maxPromptDictionaryTerms)
        if !terms.isEmpty {
            sections.append("Dictionary terms: \(terms.joined(separator: ", "))")
        }
        sections.append("Transcript:\n\(context.text)")
        return sections.joined(separator: "\n")
    }
}

private struct CorrectionEditsPayload: Codable {
    let edits: [CorrectionEdit]
}

private struct EditJSONSchema: Encodable {
    static let schema = EditJSONSchema()

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        let raw = SchemaObject(
            type: "object",
            properties: [
                "edits": SchemaArray(
                    type: "array",
                    items: SchemaEditObject(
                        type: "object",
                        properties: [
                            "original": SchemaString(type: "string"),
                            "replacement": SchemaString(type: "string"),
                        ],
                        required: ["original", "replacement"],
                        additionalProperties: false
                    )
                ),
            ],
            required: ["edits"],
            additionalProperties: false
        )
        try container.encode(raw)
    }

    private struct SchemaObject: Encodable {
        let type: String
        let properties: [String: SchemaArray]
        let required: [String]
        let additionalProperties: Bool
    }

    private struct SchemaArray: Encodable {
        let type: String
        let items: SchemaEditObject
    }

    private struct SchemaEditObject: Encodable {
        let type: String
        let properties: [String: SchemaString]
        let required: [String]
        let additionalProperties: Bool
    }

    private struct SchemaString: Encodable {
        let type: String
    }
}

enum SecretRedaction {
    static func redact(_ text: String, secret: String? = nil) -> String {
        var result = text
        if let secret, !secret.isEmpty {
            result = result.replacingOccurrences(of: secret, with: "[REDACTED]")
        }
        result = result.replacingOccurrences(
            of: #"(?i)bearer\s+[A-Za-z0-9._\-]+"#,
            with: "Bearer [REDACTED]",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"sk-[A-Za-z0-9._\-]{8,}"#,
            with: "sk-[REDACTED]",
            options: .regularExpression
        )
        return result
    }
}

// MARK: - Anthropic

public struct AnthropicCorrectionProvider: CloudCorrectionProvider {
    public let id: CloudProviderID = .anthropic
    private let transport: any HTTPTransport
    private let baseURL: URL

    public init(
        transport: any HTTPTransport = URLSessionHTTPTransport(),
        baseURL: URL = URL(string: "https://api.anthropic.com")!
    ) {
        self.transport = transport
        self.baseURL = baseURL
    }

    public func correct(
        _ context: CorrectionPromptContext,
        modelID: String,
        apiKey: String
    ) async throws -> [CorrectionEdit] {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw CloudCorrectionError.missingAPIKey(.anthropic) }

        let body = MessagesRequest(
            model: modelID,
            maxTokens: CloudCorrectionConfig.maxOutputTokens,
            stream: false,
            system: CorrectionPromptBuilder.systemPrompt,
            messages: [MessagesRequest.Message(role: "user", content: CorrectionPromptBuilder.userPrompt(for: context))],
            thinking: MessagesRequest.Thinking(type: "disabled"),
            outputConfig: MessagesRequest.OutputConfig(
                effort: "low",
                format: MessagesRequest.OutputFormat(type: "json_schema", schema: EditJSONSchema.schema)
            )
        )

        var request = URLRequest(url: baseURL.appending(path: "v1/messages"))
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue(CloudCorrectionConfig.anthropicAPIVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await perform(request, apiKey: key)
        try validateHTTP(response, data: data, provider: .anthropic, modelID: modelID, apiKey: key)

        let decoded: MessagesResponse
        do {
            decoded = try JSONDecoder().decode(MessagesResponse.self, from: data)
        } catch {
            throw CloudCorrectionError.invalidResponse("Could not decode Anthropic response.")
        }

        if decoded.stopReason == "refusal" {
            throw CloudCorrectionError.refused(nil)
        }

        guard let text = decoded.content.first(where: { $0.type == "text" })?.text,
              let jsonData = text.data(using: .utf8) else {
            throw CloudCorrectionError.invalidResponse("Anthropic response contained no text output.")
        }

        do {
            return try JSONDecoder().decode(CorrectionEditsPayload.self, from: jsonData).edits
        } catch {
            throw CloudCorrectionError.invalidResponse("Anthropic output did not match edits schema.")
        }
    }

    public func listModels(apiKey: String) async throws -> [CloudModelOption] {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw CloudCorrectionError.missingAPIKey(.anthropic) }

        var components = URLComponents(url: baseURL.appending(path: "v1/models"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "limit", value: "100")]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue(CloudCorrectionConfig.anthropicAPIVersion, forHTTPHeaderField: "anthropic-version")

        let (data, response) = try await perform(request, apiKey: key)
        try validateHTTP(response, data: data, provider: .anthropic, modelID: nil, apiKey: key)

        let decoded: ModelsResponse
        do {
            decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
        } catch {
            throw CloudCorrectionError.invalidResponse("Could not decode Anthropic models list.")
        }

        let filtered = decoded.data.compactMap { item -> CloudModelOption? in
            if let lifecycle = item.lifecycle, lifecycle != "active" {
                return nil
            }
            guard item.id.hasPrefix("claude-haiku-")
                || item.id.hasPrefix("claude-sonnet-")
                || item.id.hasPrefix("claude-opus-") else {
                return nil
            }
            if let capabilities = item.capabilities {
                if capabilities.structuredOutputs?.supported == false { return nil }
                if capabilities.thinking?.types?.disabled?.supported == false { return nil }
                if capabilities.effort?.low?.supported == false { return nil }
            }
            return CloudModelOption(id: item.id, displayName: item.displayName ?? item.id)
        }

        return prioritized(filtered, defaultOption: id.defaultModelOption)
    }

    private func perform(_ request: URLRequest, apiKey: String) async throws -> (Data, URLResponse) {
        do {
            return try await transport.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CloudCorrectionError {
            throw error
        } catch {
            throw CloudCorrectionError.networkFailure(SecretRedaction.redact(error.localizedDescription, secret: apiKey))
        }
    }

    private func prioritized(_ models: [CloudModelOption], defaultOption: CloudModelOption) -> [CloudModelOption] {
        guard !models.isEmpty else { return [defaultOption] }
        if let index = models.firstIndex(where: { $0.id == defaultOption.id }) {
            var ordered = models
            let chosen = ordered.remove(at: index)
            ordered.insert(chosen, at: 0)
            return ordered
        }
        return models
    }

    private struct MessagesRequest: Encodable {
        let model: String
        let maxTokens: Int
        let stream: Bool
        let system: String
        let messages: [Message]
        let thinking: Thinking
        let outputConfig: OutputConfig

        enum CodingKeys: String, CodingKey {
            case model
            case maxTokens = "max_tokens"
            case stream
            case system
            case messages
            case thinking
            case outputConfig = "output_config"
        }

        struct Message: Encodable {
            let role: String
            let content: String
        }

        struct Thinking: Encodable {
            let type: String
        }

        struct OutputConfig: Encodable {
            let effort: String
            let format: OutputFormat
        }

        struct OutputFormat: Encodable {
            let type: String
            let schema: EditJSONSchema
        }
    }

    private struct MessagesResponse: Decodable {
        let content: [ContentBlock]
        let stopReason: String?

        enum CodingKeys: String, CodingKey {
            case content
            case stopReason = "stop_reason"
        }

        struct ContentBlock: Decodable {
            let type: String
            let text: String?
        }
    }

    private struct ModelsResponse: Decodable {
        let data: [ModelInfo]

        struct ModelInfo: Decodable {
            let id: String
            let displayName: String?
            let lifecycle: String?
            let capabilities: Capabilities?

            enum CodingKeys: String, CodingKey {
                case id
                case displayName = "display_name"
                case lifecycle
                case capabilities
            }
        }

        struct Capabilities: Decodable {
            let structuredOutputs: SupportFlag?
            let thinking: ThinkingCapabilities?
            let effort: EffortCapabilities?

            enum CodingKeys: String, CodingKey {
                case structuredOutputs = "structured_outputs"
                case thinking
                case effort
            }
        }

        struct SupportFlag: Decodable {
            let supported: Bool
        }

        struct ThinkingCapabilities: Decodable {
            let types: ThinkingTypes?
        }

        struct ThinkingTypes: Decodable {
            let disabled: SupportFlag?
        }

        struct EffortCapabilities: Decodable {
            let low: SupportFlag?
        }
    }
}

// MARK: - OpenAI

public struct OpenAICorrectionProvider: CloudCorrectionProvider {
    public let id: CloudProviderID = .openAI
    private let transport: any HTTPTransport
    private let baseURL: URL
    private let todayProvider: @Sendable () -> Date

    public init(
        transport: any HTTPTransport = URLSessionHTTPTransport(),
        baseURL: URL = URL(string: "https://api.openai.com")!,
        todayProvider: @escaping @Sendable () -> Date = { Date.now }
    ) {
        self.transport = transport
        self.baseURL = baseURL
        self.todayProvider = todayProvider
    }

    public func correct(
        _ context: CorrectionPromptContext,
        modelID: String,
        apiKey: String
    ) async throws -> [CorrectionEdit] {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw CloudCorrectionError.missingAPIKey(.openAI) }

        let body = ResponsesRequest(
            model: modelID,
            store: false,
            maxOutputTokens: CloudCorrectionConfig.maxOutputTokens,
            stream: false,
            instructions: CorrectionPromptBuilder.systemPrompt,
            input: CorrectionPromptBuilder.userPrompt(for: context),
            reasoning: ResponsesRequest.Reasoning(effort: "none"),
            text: ResponsesRequest.TextConfig(
                format: ResponsesRequest.TextFormat(
                    type: "json_schema",
                    name: "transcript_edits",
                    strict: true,
                    schema: EditJSONSchema.schema
                )
            )
        )

        var request = URLRequest(url: baseURL.appending(path: "v1/responses"))
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await perform(request, apiKey: key)
        try validateHTTP(response, data: data, provider: .openAI, modelID: modelID, apiKey: key)

        let decoded: ResponsesResponse
        do {
            decoded = try JSONDecoder().decode(ResponsesResponse.self, from: data)
        } catch {
            throw CloudCorrectionError.invalidResponse("Could not decode OpenAI response.")
        }

        if let status = decoded.status, status != "completed" {
            if let reason = decoded.incompleteDetails?.reason {
                throw CloudCorrectionError.invalidResponse("OpenAI response incomplete (\(reason)).")
            }
            throw CloudCorrectionError.invalidResponse("OpenAI response status was \(status).")
        }

        let contents = decoded.output
            .filter { $0.type == "message" }
            .flatMap { $0.content ?? [] }

        if let refusal = contents.first(where: { $0.type == "refusal" }) {
            throw CloudCorrectionError.refused(refusal.refusal)
        }

        guard let text = contents.first(where: { $0.type == "output_text" })?.text,
              let jsonData = text.data(using: .utf8) else {
            throw CloudCorrectionError.invalidResponse("OpenAI response contained no text output.")
        }

        do {
            return try JSONDecoder().decode(CorrectionEditsPayload.self, from: jsonData).edits
        } catch {
            throw CloudCorrectionError.invalidResponse("OpenAI output did not match edits schema.")
        }
    }

    public func listModels(apiKey: String) async throws -> [CloudModelOption] {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw CloudCorrectionError.missingAPIKey(.openAI) }

        var request = URLRequest(url: baseURL.appending(path: "v1/models"))
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await perform(request, apiKey: key)
        try validateHTTP(response, data: data, provider: .openAI, modelID: nil, apiKey: key)

        let decoded: ModelsResponse
        do {
            decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
        } catch {
            throw CloudCorrectionError.invalidResponse("Could not decode OpenAI models list.")
        }

        let today = Self.utcDateFormatter.string(from: todayProvider())
        let availableIDs = Set(decoded.data.compactMap { item -> String? in
            guard CloudCorrectionConfig.openAIAllowlistedModelIDs.contains(item.id) else {
                return nil
            }
            if let shutdownDate = item.shutdownDate, !shutdownDate.isEmpty, shutdownDate <= today {
                return nil
            }
            return item.id
        })

        let ordered = CloudCorrectionConfig.openAIAllowlistedModelIDs
            .filter { availableIDs.contains($0) }
            .map { CloudModelOption(id: $0, displayName: Self.displayName(for: $0)) }

        return ordered.isEmpty ? [id.defaultModelOption] : ordered
    }

    private func perform(_ request: URLRequest, apiKey: String) async throws -> (Data, URLResponse) {
        do {
            return try await transport.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CloudCorrectionError {
            throw error
        } catch {
            throw CloudCorrectionError.networkFailure(SecretRedaction.redact(error.localizedDescription, secret: apiKey))
        }
    }

    private static func displayName(for id: String) -> String {
        switch id {
        case "gpt-6-luna": return "GPT-6 Luna"
        case "gpt-6.1-terra": return "GPT-6.1 Terra"
        case "gpt-6-sol": return "GPT-6 Sol"
        default: return id
        }
    }

    private static let utcDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private struct ResponsesRequest: Encodable {
        let model: String
        let store: Bool
        let maxOutputTokens: Int
        let stream: Bool
        let instructions: String
        let input: String
        let reasoning: Reasoning
        let text: TextConfig

        enum CodingKeys: String, CodingKey {
            case model
            case store
            case maxOutputTokens = "max_output_tokens"
            case stream
            case instructions
            case input
            case reasoning
            case text
        }

        struct Reasoning: Encodable {
            let effort: String
        }

        struct TextConfig: Encodable {
            let format: TextFormat
        }

        struct TextFormat: Encodable {
            let type: String
            let name: String
            let strict: Bool
            let schema: EditJSONSchema
        }
    }

    private struct ResponsesResponse: Decodable {
        let status: String?
        let incompleteDetails: IncompleteDetails?
        let output: [OutputItem]

        enum CodingKeys: String, CodingKey {
            case status
            case incompleteDetails = "incomplete_details"
            case output
        }

        struct IncompleteDetails: Decodable {
            let reason: String?
        }

        struct OutputItem: Decodable {
            let type: String
            let content: [ContentItem]?
        }

        struct ContentItem: Decodable {
            let type: String
            let text: String?
            let refusal: String?
        }
    }

    private struct ModelsResponse: Decodable {
        let data: [ModelInfo]

        struct ModelInfo: Decodable {
            let id: String
            let shutdownDate: String?

            enum CodingKeys: String, CodingKey {
                case id
                case shutdownDate = "shutdown_date"
            }
        }
    }
}

// MARK: - Shared HTTP Validation

private struct ProviderErrorEnvelope: Decodable {
    let error: ErrorDetail?

    struct ErrorDetail: Decodable {
        let message: String?
        let type: String?
        let code: String?
    }
}

private func validateHTTP(
    _ response: URLResponse,
    data: Data,
    provider: CloudProviderID,
    modelID: String?,
    apiKey: String
) throws {
    guard let http = response as? HTTPURLResponse else {
        throw CloudCorrectionError.invalidResponse("Response was not HTTP.")
    }
    guard (200..<300).contains(http.statusCode) else {
        let rawMessage = (try? JSONDecoder().decode(ProviderErrorEnvelope.self, from: data))?.error?.message ?? ""
        let message = SecretRedaction.redact(rawMessage, secret: apiKey)
        switch http.statusCode {
        case 401, 403:
            throw CloudCorrectionError.invalidAPIKey(provider)
        case 404:
            if let modelID {
                throw CloudCorrectionError.modelUnavailable(modelID)
            }
            throw CloudCorrectionError.httpError(statusCode: http.statusCode, message: message)
        case 429:
            throw CloudCorrectionError.rateLimited(provider)
        default:
            throw CloudCorrectionError.httpError(statusCode: http.statusCode, message: message)
        }
    }
}
