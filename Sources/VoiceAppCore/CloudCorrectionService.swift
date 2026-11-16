import Foundation
import OSLog

public protocol CloudCorrecting: AnyObject, Sendable {
    @MainActor
    func correct(
        _ text: String,
        dictionaryTerms: [String],
        protectedRanges: [Range<String.Index>],
        appBundleID: String?,
        appName: String?
    ) async -> CorrectionOutcome

    @MainActor
    func correct(
        _ text: String,
        dictionaryTerms: [String],
        protectedRanges: [Range<String.Index>],
        appBundleID: String?,
        appName: String?,
        willSendRequest: @escaping @MainActor () -> Void
    ) async -> CorrectionOutcome
}

public extension CloudCorrecting {
    @MainActor
    func correct(
        _ text: String,
        dictionaryTerms: [String],
        protectedRanges: [Range<String.Index>],
        appBundleID: String?,
        appName: String?,
        willSendRequest: @escaping @MainActor () -> Void
    ) async -> CorrectionOutcome {
        willSendRequest()
        return await correct(
            text,
            dictionaryTerms: dictionaryTerms,
            protectedRanges: protectedRanges,
            appBundleID: appBundleID,
            appName: appName
        )
    }

    @MainActor
    func correct(
        _ text: String,
        dictionaryTerms: [String],
        appBundleID: String?,
        appName: String?
    ) async -> CorrectionOutcome {
        await correct(
            text,
            dictionaryTerms: dictionaryTerms,
            protectedRanges: [],
            appBundleID: appBundleID,
            appName: appName
        )
    }
}

public struct CorrectionCircuitBreaker: Sendable {
    public private(set) var consecutiveFailures = 0
    public private(set) var openUntil: ContinuousClock.Instant?

    private let failureThreshold: Int
    private let cooldown: Duration
    private let now: @Sendable () -> ContinuousClock.Instant

    public init(
        failureThreshold: Int = CloudCorrectionConfig.circuitBreakerFailureThreshold,
        cooldown: Duration = CloudCorrectionConfig.circuitBreakerCooldown,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.failureThreshold = max(1, failureThreshold)
        self.cooldown = cooldown
        self.now = now
    }

    public var isOpen: Bool {
        guard let openUntil else { return false }
        return now() < openUntil
    }

    public mutating func canAttempt() -> Bool {
        !isOpen
    }

    public mutating func recordSuccess() {
        consecutiveFailures = 0
        openUntil = nil
    }

    public mutating func recordFailure() {
        if openUntil != nil {
            consecutiveFailures = failureThreshold
            openUntil = now().advanced(by: cooldown)
            return
        }
        consecutiveFailures += 1
        if consecutiveFailures >= failureThreshold {
            openUntil = now().advanced(by: cooldown)
        }
    }

    public mutating func reset() {
        consecutiveFailures = 0
        openUntil = nil
    }
}

@MainActor
public final class CloudCorrectionService: ObservableObject, CloudCorrecting {
    public enum TestState: Equatable {
        case idle
        case testing
        case succeeded(latencyMilliseconds: Int, modelID: String)
        case failed(String)
    }

    public static let enabledKey = "cloudCorrectionEnabled"
    public static let providerKey = "cloudCorrectionProvider"
    public static let excludedBundleIDsKey = "cloudCorrectionExcludedBundleIDs"

    public static func modelKey(for provider: CloudProviderID) -> String {
        "cloudCorrectionModel.\(provider.rawValue)"
    }

    @Published public var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Self.enabledKey)
            circuitBreaker.reset()
        }
    }

    @Published public var selectedProvider: CloudProviderID {
        didSet {
            guard selectedProvider != oldValue else { return }
            defaults.set(selectedProvider.rawValue, forKey: Self.providerKey)
            circuitBreaker.reset()
            testState = .idle
            modelsError = nil
        }
    }

    @Published public private(set) var selectedModels: [CloudProviderID: String]
    @Published public private(set) var availableModels: [CloudProviderID: [CloudModelOption]]
    @Published public private(set) var hasKeyByProvider: [CloudProviderID: Bool]
    @Published public private(set) var excludedBundleIDs: [String]
    @Published public private(set) var isRefreshingModels = false
    @Published public private(set) var modelsError: String?
    @Published public private(set) var testState: TestState = .idle
    @Published public private(set) var keyStoreError: String?
    @Published public private(set) var isCircuitOpen = false

    public var isActive: Bool {
        isEnabled && hasKey(for: selectedProvider)
    }

    public var currentModelID: String {
        selectedModelID(for: selectedProvider)
    }

    public var currentModels: [CloudModelOption] {
        let fetched = availableModels[selectedProvider] ?? [selectedProvider.defaultModelOption]
        let current = currentModelID
        if fetched.contains(where: { $0.id == current }) {
            return fetched
        }
        return [CloudModelOption(id: current)] + fetched
    }

    private let secretStore: any SecretStore
    private let providers: [CloudProviderID: any CloudCorrectionProvider]
    private let defaults: UserDefaults
    private let deadline: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private let log: @Sendable (String) -> Void
    private var circuitBreaker: CorrectionCircuitBreaker
    private var keyWriteGeneration: [CloudProviderID: Int] = [:]

    private nonisolated static let defaultSleep: @Sendable (Duration) async throws -> Void = {
        try await Task.sleep(for: $0)
    }

    public convenience init(
        secretStore: any SecretStore = KeychainSecretStore(),
        transport: any HTTPTransport = URLSessionHTTPTransport(),
        defaults: UserDefaults = .standard,
        deadline: Duration = CloudCorrectionConfig.requestDeadline,
        sleep: (@Sendable (Duration) async throws -> Void)? = nil,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
        log: @escaping @Sendable (String) -> Void = {
            Logger(subsystem: "com.local.voiceapp", category: "CloudCorrection").error("\($0, privacy: .public)")
        }
    ) {
        self.init(
            secretStore: secretStore,
            providers: [
                .anthropic: AnthropicCorrectionProvider(transport: transport),
                .openAI: OpenAICorrectionProvider(transport: transport),
            ],
            defaults: defaults,
            deadline: deadline,
            sleep: sleep,
            now: now,
            log: log
        )
    }

    public init(
        secretStore: any SecretStore,
        providers: [CloudProviderID: any CloudCorrectionProvider],
        defaults: UserDefaults = .standard,
        deadline: Duration = CloudCorrectionConfig.requestDeadline,
        sleep: (@Sendable (Duration) async throws -> Void)? = nil,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
        log: @escaping @Sendable (String) -> Void = {
            Logger(subsystem: "com.local.voiceapp", category: "CloudCorrection").error("\($0, privacy: .public)")
        }
    ) {
        self.secretStore = secretStore
        self.providers = providers
        self.defaults = defaults
        self.deadline = deadline
        self.sleep = sleep ?? Self.defaultSleep
        self.log = log
        self.circuitBreaker = CorrectionCircuitBreaker(now: now)

        self.isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? false
        if let rawProvider = defaults.string(forKey: Self.providerKey),
           let parsed = CloudProviderID(rawValue: rawProvider) {
            self.selectedProvider = parsed
        } else {
            self.selectedProvider = .anthropic
        }

        var modelsByProvider: [CloudProviderID: String] = [:]
        var optionsByProvider: [CloudProviderID: [CloudModelOption]] = [:]
        var keysPresent: [CloudProviderID: Bool] = [:]
        for provider in CloudProviderID.allCases {
            let storedModel = defaults.string(forKey: Self.modelKey(for: provider))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            modelsByProvider[provider] = (storedModel?.isEmpty == false) ? storedModel! : provider.defaultModelID
            optionsByProvider[provider] = [provider.defaultModelOption]
            keysPresent[provider] = false
        }
        self.selectedModels = modelsByProvider
        self.availableModels = optionsByProvider
        self.hasKeyByProvider = keysPresent

        let rawExcluded = defaults.stringArray(forKey: Self.excludedBundleIDsKey) ?? []
        self.excludedBundleIDs = Self.normalizedBundleIDList(rawExcluded)
    }

    // MARK: - Keychain & Settings

    public func hasKey(for provider: CloudProviderID) -> Bool {
        hasKeyByProvider[provider] ?? false
    }

    public func refreshKeyPresence(for provider: CloudProviderID? = nil) async {
        let targets = provider.map { [$0] } ?? CloudProviderID.allCases
        for target in targets {
            let generation = keyWriteGeneration[target, default: 0]
            switch await readAPIKeyOffMainActor(for: target, within: deadline) {
            case .found:
                if keyWriteGeneration[target, default: 0] == generation {
                    hasKeyByProvider[target] = true
                    keyStoreError = nil
                }
            case .missing:
                if keyWriteGeneration[target, default: 0] == generation {
                    hasKeyByProvider[target] = false
                }
            case .failed(let message):
                if keyWriteGeneration[target, default: 0] == generation {
                    hasKeyByProvider[target] = false
                    keyStoreError = message
                }
            case .timedOut:
                if keyWriteGeneration[target, default: 0] == generation {
                    hasKeyByProvider[target] = false
                    keyStoreError = "Reading API key from Keychain timed out."
                }
            }
        }
    }

    public func selectedModelID(for provider: CloudProviderID) -> String {
        selectedModels[provider] ?? provider.defaultModelID
    }

    public func setSelectedModelID(_ modelID: String, for provider: CloudProviderID? = nil) {
        let target = provider ?? selectedProvider
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = trimmed.isEmpty ? target.defaultModelID : trimmed
        selectedModels[target] = resolved
        defaults.set(resolved, forKey: Self.modelKey(for: target))
        circuitBreaker.reset()
        isCircuitOpen = circuitBreaker.isOpen
        testState = .idle
    }

    public func saveAPIKey(_ rawKey: String, for provider: CloudProviderID? = nil) throws {
        let target = provider ?? selectedProvider
        let trimmed = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        keyStoreError = nil
        do {
            keyWriteGeneration[target, default: 0] += 1
            if trimmed.isEmpty {
                try secretStore.delete(account: target.rawValue)
                hasKeyByProvider[target] = false
                availableModels[target] = [target.defaultModelOption]
            } else {
                try secretStore.write(trimmed, account: target.rawValue)
                hasKeyByProvider[target] = true
            }
            circuitBreaker.reset()
            isCircuitOpen = circuitBreaker.isOpen
            testState = .idle
            modelsError = nil
        } catch {
            keyStoreError = error.localizedDescription
            throw error
        }
    }

    public func removeAPIKey(for provider: CloudProviderID? = nil) throws {
        let target = provider ?? selectedProvider
        keyStoreError = nil
        do {
            keyWriteGeneration[target, default: 0] += 1
            try secretStore.delete(account: target.rawValue)
            hasKeyByProvider[target] = false
            availableModels[target] = [target.defaultModelOption]
            circuitBreaker.reset()
            isCircuitOpen = circuitBreaker.isOpen
            testState = .idle
            modelsError = nil
        } catch {
            keyStoreError = error.localizedDescription
            throw error
        }
    }

    // MARK: - App Exclusion

    public func isAppExcluded(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        let normalized = bundleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        return excludedBundleIDs.contains { $0.lowercased() == normalized }
    }

    public func addExcludedBundleID(_ bundleID: String) {
        let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let updated = Self.normalizedBundleIDList(excludedBundleIDs + [trimmed])
        excludedBundleIDs = updated
        defaults.set(updated, forKey: Self.excludedBundleIDsKey)
    }

    public func removeExcludedBundleID(_ bundleID: String) {
        let needle = bundleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        excludedBundleIDs.removeAll { $0.lowercased() == needle }
        defaults.set(excludedBundleIDs, forKey: Self.excludedBundleIDsKey)
    }

    // MARK: - Models & Test

    @discardableResult
    public func refreshModels(for provider: CloudProviderID? = nil) async -> [CloudModelOption] {
        let target = provider ?? selectedProvider
        modelsError = nil
        guard let impl = providers[target] else {
            return availableModels[target] ?? [target.defaultModelOption]
        }
        let apiKey: String
        switch await readAPIKeyOffMainActor(for: target, within: deadline) {
        case .found(let key):
            hasKeyByProvider[target] = true
            apiKey = key
        case .missing:
            hasKeyByProvider[target] = false
            return [target.defaultModelOption]
        case .failed(let message):
            hasKeyByProvider[target] = false
            modelsError = message
            return availableModels[target] ?? [target.defaultModelOption]
        case .timedOut:
            hasKeyByProvider[target] = false
            modelsError = "Timed out reading API key from Keychain."
            return availableModels[target] ?? [target.defaultModelOption]
        }
        isRefreshingModels = true
        defer { isRefreshingModels = false }
        do {
            let models = try await impl.listModels(apiKey: apiKey)
            availableModels[target] = models
            return models
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            modelsError = SecretRedaction.redact(message, secret: apiKey)
            log("Failed to list models for provider=\(target.rawValue): \(modelsError ?? "")")
            return availableModels[target] ?? [target.defaultModelOption]
        }
    }

    public func testConnection() async {
        let target = selectedProvider
        guard let impl = providers[target] else { return }
        let apiKey: String
        switch await readAPIKeyOffMainActor(for: target, within: deadline) {
        case .found(let key):
            hasKeyByProvider[target] = true
            apiKey = key
        case .missing:
            hasKeyByProvider[target] = false
            testState = .failed(CloudCorrectionError.missingAPIKey(target).localizedDescription)
            return
        case .failed(let message):
            hasKeyByProvider[target] = false
            testState = .failed(message)
            return
        case .timedOut:
            hasKeyByProvider[target] = false
            testState = .failed("Timed out reading API key from Keychain.")
            return
        }

        let modelID = selectedModelID(for: target)
        testState = .testing
        let clock = ContinuousClock()
        let start = clock.now
        let context = CorrectionPromptContext(
            text: "I would load to test this.",
            dictionaryTerms: [],
            appName: nil
        )
        do {
            let edits = try await raceWithDeadline(.seconds(10)) {
                try await impl.correct(context, modelID: modelID, apiKey: apiKey)
            }
            _ = try CorrectionEditValidator.apply(edits, to: context.text)
            let elapsed = start.duration(to: clock.now)
            let ms = max(1, Int(elapsed.components.seconds * 1000) + Int(elapsed.components.attoseconds / 1_000_000_000_000_000))
            circuitBreaker.reset()
            isCircuitOpen = false
            testState = .succeeded(latencyMilliseconds: ms, modelID: modelID)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            let safe = SecretRedaction.redact(message, secret: apiKey)
            testState = .failed(safe)
            log("Connection test failed for provider=\(target.rawValue) model=\(modelID): \(safe)")
        }
    }

    // MARK: - Dictation Pipeline Correction

    public func correct(
        _ text: String,
        dictionaryTerms: [String],
        protectedRanges: [Range<String.Index>],
        appBundleID: String?,
        appName: String?
    ) async -> CorrectionOutcome {
        await correct(
            text,
            dictionaryTerms: dictionaryTerms,
            protectedRanges: protectedRanges,
            appBundleID: appBundleID,
            appName: appName,
            willSendRequest: {}
        )
    }

    public func correct(
        _ text: String,
        dictionaryTerms: [String],
        protectedRanges: [Range<String.Index>],
        appBundleID: String?,
        appName: String?,
        willSendRequest: @escaping @MainActor () -> Void
    ) async -> CorrectionOutcome {
        guard isEnabled else {
            return CorrectionOutcome(outputText: text)
        }

        let providerID = selectedProvider
        let modelID = selectedModelID(for: providerID)

        if isAppExcluded(bundleID: appBundleID) {
            return CorrectionOutcome(
                outputText: text,
                provider: providerID,
                modelID: modelID,
                status: .skipped,
                reason: "App excluded"
            )
        }

        guard CorrectionEditValidator.wordTokens(in: text).count >= CloudCorrectionConfig.minWordsForCloudCorrection else {
            return CorrectionOutcome(outputText: text, provider: providerID, modelID: modelID,
                                     status: .skipped, reason: "too short")
        }

        guard circuitBreaker.canAttempt() else {
            isCircuitOpen = true
            return CorrectionOutcome(
                inputText: text,
                outputText: text,
                provider: providerID,
                modelID: modelID,
                status: .fallback,
                reason: "Paused for 5 minutes after 3 consecutive failures"
            )
        }

        guard let impl = providers[providerID] else {
            return CorrectionOutcome(
                inputText: text,
                outputText: text,
                provider: providerID,
                modelID: modelID,
                status: .fallback,
                reason: "Provider unavailable"
            )
        }

        let promptContext = CorrectionPromptContext(
            text: text,
            dictionaryTerms: dictionaryTerms,
            appName: appName
        )
        let store = self.secretStore
        let stage = DeadlineStageTracker()
        let callbackBox = MainActorCallbackBox(willSendRequest)

        do {
            let raced = try await raceWithDeadline(deadline) {
                let apiKey: String?
                do {
                    apiKey = try await Self.readSecretOffMainActor(secretStore: store, account: providerID.rawValue)
                } catch {
                    try Task.checkCancellation()
                    stage.markKeyReadCompleted()
                    return RacedCorrectionResult.keyReadFailed(error)
                }
                try Task.checkCancellation()
                stage.markKeyReadCompleted()
                guard let apiKey else {
                    return RacedCorrectionResult.missingKey
                }
                await MainActor.run {
                    callbackBox.call()
                }
                try Task.checkCancellation()
                do {
                    let edits = try await impl.correct(promptContext, modelID: modelID, apiKey: apiKey)
                    return RacedCorrectionResult.edits(edits, apiKey: apiKey)
                } catch {
                    return RacedCorrectionResult.providerFailed(error, apiKey: apiKey)
                }
            }

            switch raced {
            case .missingKey:
                hasKeyByProvider[providerID] = false
                return CorrectionOutcome(outputText: text)

            case .keyReadFailed(let error):
                hasKeyByProvider[providerID] = false
                let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                log("Skipped cloud correction for provider=\(providerID.rawValue): \(reason)")
                return CorrectionOutcome(
                    outputText: text,
                    provider: providerID,
                    modelID: modelID,
                    status: .skipped,
                    reason: reason
                )

            case .providerFailed(let error, let apiKey):
                hasKeyByProvider[providerID] = true
                circuitBreaker.recordFailure()
                isCircuitOpen = circuitBreaker.isOpen
                let rawReason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                let reason = SecretRedaction.redact(rawReason, secret: apiKey)
                log("Cloud correction failed for provider=\(providerID.rawValue) model=\(modelID): \(reason)")
                return CorrectionOutcome(
                    inputText: text,
                    outputText: text,
                    provider: providerID,
                    modelID: modelID,
                    status: .fallback,
                    reason: reason
                )

            case .edits(let edits, _):
                hasKeyByProvider[providerID] = true
                do {
                    let updated = try CorrectionEditValidator.apply(
                        edits,
                        to: text,
                        protectedRanges: protectedRanges
                    )
                    circuitBreaker.recordSuccess()
                    isCircuitOpen = false
                    let changed = updated != text
                    return CorrectionOutcome(
                        inputText: text,
                        outputText: updated,
                        provider: providerID,
                        modelID: modelID,
                        status: changed ? .applied : .unchanged,
                        edits: edits
                    )
                } catch let error as EditValidationError {
                    circuitBreaker.recordFailure()
                    isCircuitOpen = circuitBreaker.isOpen
                    let reason = error.errorDescription ?? "Invalid edits rejected"
                    log("Rejected model edits for provider=\(providerID.rawValue) model=\(modelID): \(reason)")
                    return CorrectionOutcome(
                        inputText: text,
                        outputText: text,
                        provider: providerID,
                        modelID: modelID,
                        status: .fallback,
                        reason: reason
                    )
                }
            }
        } catch let error as CloudCorrectionError where error == .timedOut(deadline) {
            if !stage.didCompleteKeyRead {
                let reason = "Timed out reading API key from Keychain."
                log("Skipped cloud correction for provider=\(providerID.rawValue): \(reason)")
                return CorrectionOutcome(
                    outputText: text,
                    provider: providerID,
                    modelID: modelID,
                    status: .skipped,
                    reason: reason
                )
            }
            circuitBreaker.recordFailure()
            isCircuitOpen = circuitBreaker.isOpen
            let reason = error.errorDescription ?? "Timed out."
            log("Cloud correction failed for provider=\(providerID.rawValue) model=\(modelID): \(reason)")
            return CorrectionOutcome(
                inputText: text,
                outputText: text,
                provider: providerID,
                modelID: modelID,
                status: .fallback,
                reason: reason
            )
        } catch {
            circuitBreaker.recordFailure()
            isCircuitOpen = circuitBreaker.isOpen
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            log("Cloud correction failed for provider=\(providerID.rawValue) model=\(modelID): \(reason)")
            return CorrectionOutcome(
                inputText: text,
                outputText: text,
                provider: providerID,
                modelID: modelID,
                status: .fallback,
                reason: reason
            )
        }
    }

    // MARK: - Helpers

    private enum KeyReadStatus {
        case found(String)
        case missing
        case failed(String)
        case timedOut
    }

    private func readAPIKeyOffMainActor(for provider: CloudProviderID, within limit: Duration) async -> KeyReadStatus {
        let store = self.secretStore
        do {
            let key = try await raceWithDeadline(limit) {
                try await Self.readSecretOffMainActor(secretStore: store, account: provider.rawValue)
            }
            return key.map { .found($0) } ?? .missing
        } catch let error as CloudCorrectionError where error == .timedOut(limit) {
            return .timedOut
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            log("Could not read API key from Keychain for provider=\(provider.rawValue): \(message)")
            return .failed(message)
        }
    }

    private static func readSecretOffMainActor(
        secretStore: any SecretStore,
        account: String
    ) async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let raw = try secretStore.read(account: account)
                    let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(returning: (trimmed?.isEmpty == false) ? trimmed : nil)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func raceWithDeadline<T: Sendable>(
        _ limit: Duration,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        let sleepFn = self.sleep
        let box = DeadlineHandleBox<T>()

        let outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<DeadlineRaceOutcome<T>, Never>) in
                let handle = DeadlineRaceHandle(continuation)
                guard box.attach(handle) else {
                    return
                }
                let req = Task.detached(priority: .userInitiated) {
                    do {
                        let value = try await operation()
                        _ = handle.resume(.success(value))
                    } catch {
                        _ = handle.resume(.failure(error))
                    }
                }
                let timer = Task.detached(priority: .userInitiated) {
                    do {
                        try await sleepFn(limit)
                        guard !Task.isCancelled else { return }
                        _ = handle.resume(.timedOut)
                    } catch {
                    }
                }
                handle.attachTasks(request: req, timer: timer)
            }
        } onCancel: {
            box.cancel()
        }

        switch outcome {
        case .success(let value):
            return value
        case .failure(let error):
            throw error
        case .timedOut:
            throw CloudCorrectionError.timedOut(limit)
        }
    }

    private static func normalizedBundleIDList(_ raw: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for entry in raw {
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = trimmed.lowercased()
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            result.append(trimmed)
        }
        return result.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}

private enum RacedCorrectionResult: @unchecked Sendable {
    case missingKey
    case keyReadFailed(any Error)
    case providerFailed(any Error, apiKey: String)
    case edits([CorrectionEdit], apiKey: String)
}

private final class DeadlineStageTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var keyReadCompleted = false

    var didCompleteKeyRead: Bool {
        lock.withLock { keyReadCompleted }
    }

    func markKeyReadCompleted() {
        lock.withLock { keyReadCompleted = true }
    }
}

private final class MainActorCallbackBox: @unchecked Sendable {
    private let body: @MainActor () -> Void

    init(_ body: @escaping @MainActor () -> Void) {
        self.body = body
    }

    @MainActor
    func call() {
        body()
    }
}

private enum DeadlineRaceOutcome<Value: Sendable>: Sendable {
    case success(Value)
    case failure(any Error)
    case timedOut
}

private final class DeadlineRaceHandle<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<DeadlineRaceOutcome<Value>, Never>?
    private var requestTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var cancelled = false

    init(_ continuation: CheckedContinuation<DeadlineRaceOutcome<Value>, Never>) {
        self.continuation = continuation
    }

    func attachTasks(request: Task<Void, Never>, timer: Task<Void, Never>) {
        let cancelRequest: Bool
        let cancelTimer: Bool
        lock.lock()
        if cancelled {
            cancelRequest = true
            cancelTimer = true
        } else if continuation == nil {
            cancelRequest = false
            cancelTimer = true
        } else {
            requestTask = request
            timerTask = timer
            cancelRequest = false
            cancelTimer = false
        }
        lock.unlock()

        if cancelRequest {
            request.cancel()
        }
        if cancelTimer {
            timer.cancel()
        }
    }

    func resume(_ outcome: DeadlineRaceOutcome<Value>) -> Bool {
        lock.lock()
        let cont = continuation
        continuation = nil
        let req = requestTask
        let timer = timerTask
        requestTask = nil
        timerTask = nil
        lock.unlock()

        guard let cont else { return false }
        if case .timedOut = outcome {
            req?.cancel()
        }
        timer?.cancel()
        cont.resume(returning: outcome)
        return true
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let cont = continuation
        continuation = nil
        let req = requestTask
        let timer = timerTask
        requestTask = nil
        timerTask = nil
        lock.unlock()

        req?.cancel()
        timer?.cancel()
        cont?.resume(returning: .failure(CancellationError()))
    }
}

private final class DeadlineHandleBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: DeadlineRaceHandle<Value>?
    private var cancelled = false

    func attach(_ handle: DeadlineRaceHandle<Value>) -> Bool {
        lock.lock()
        if cancelled {
            lock.unlock()
            handle.cancel()
            return false
        }
        self.handle = handle
        lock.unlock()
        return true
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let current = handle
        handle = nil
        lock.unlock()
        current?.cancel()
    }
}

