import Foundation
import WhisperKit

/// Owns the on-disk model store and the currently loaded WhisperKit pipeline.
@MainActor
final class ModelManager: ObservableObject {
    enum DownloadState: Equatable {
        case notDownloaded
        case downloading(progress: Double)
        case downloaded
        case deleting
    }

    /// Load state of the *selected* model.
    enum LoadState: Equatable {
        case unloaded
        case loading
        case loaded
        case failed(String)
    }

    enum TranscriptionError: LocalizedError {
        case modelNotReady

        var errorDescription: String? {
            switch self {
            case .modelNotReady:
                return "No speech model is ready. Download and select a model in Settings."
            }
        }
    }

    /// Selected model loaded and usable for `transcribe`.
    @Published private(set) var isReady = false
    @Published private(set) var loadState: LoadState = .unloaded
    @Published private(set) var downloadStates: [String: DownloadState] = [:]
    /// Last download/delete error, for display in Settings.
    @Published var lastError: String?

    @Published var selectedModelID: String {
        didSet {
            guard selectedModelID != oldValue else { return }
            UserDefaults.standard.set(selectedModelID, forKey: Keys.selectedModel)
            loadSelectedModel()
        }
    }

    /// Whisper language code, `nil` = auto-detect.
    @Published var languageCode: String? {
        didSet { UserDefaults.standard.set(languageCode, forKey: Keys.language) }
    }

    private var whisperKit: WhisperKit?
    private var parakeet: ParakeetEngine?
    private var loadedModelID: String?
    private var loadTask: Task<Void, Never>?
    private var downloadTasks: [String: Task<Void, Never>] = [:]
    private var deletionTasks: [String: Task<Void, Never>] = [:]

    private enum Keys {
        static let selectedModel = "selectedModelID"
        static let language = "transcriptionLanguage"
    }

    private static let repo = "argmaxinc/whisperkit-coreml"
    private static let completionMarker = ".voiceapp-complete"

    /// `~/Library/Application Support/VoiceApp/models`, passed to WhisperKit as `downloadBase`.
    static let downloadBase: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appending(path: "VoiceApp/models", directoryHint: .isDirectory)
    }()

    /// Where the Hub client stores this repo: `<downloadBase>/models/<repo id>`.
    private static var repoFolder: URL {
        downloadBase.appending(path: "models").appending(path: repo)
    }

    /// FluidAudio keeps Parakeet in `<downloadBase>/parakeet/<repo folder>`.
    private static var parakeetRoot: URL {
        downloadBase.appending(path: "parakeet", directoryHint: .isDirectory)
    }

    static func folder(for modelID: String) -> URL {
        if TranscriptionModel.model(withID: modelID)?.engine == .parakeet {
            return parakeetRoot.appending(path: "parakeet-tdt-0.6b-v3", directoryHint: .isDirectory)
        }
        return repoFolder.appending(path: modelID, directoryHint: .isDirectory)
    }

    init() {
        let defaults = UserDefaults.standard
        let storedID = defaults.string(forKey: Keys.selectedModel)
        selectedModelID = storedID.flatMap(TranscriptionModel.model(withID:))?.id ?? TranscriptionModel.defaultID
        languageCode = defaults.string(forKey: Keys.language)

        try? FileManager.default.createDirectory(at: Self.downloadBase, withIntermediateDirectories: true)
        refreshDownloadStates()
        loadSelectedModel()
    }

    // MARK: - Queries

    var selectedModel: TranscriptionModel? {
        TranscriptionModel.model(withID: selectedModelID)
    }

    var downloadedModels: [TranscriptionModel] {
        TranscriptionModel.all.filter { downloadState(for: $0.id) == .downloaded }
    }

    func downloadState(for modelID: String) -> DownloadState {
        downloadStates[modelID] ?? .notDownloaded
    }

    /// Human-readable one-liner for the menu bar.
    var statusDescription: String {
        guard let model = selectedModel else { return "No model selected" }
        switch loadState {
        case .loaded:
            return "\(model.displayName) ready"
        case .loading:
            return "Loading \(model.displayName)…"
        case .failed(let message):
            return "Failed to load: \(message)"
        case .unloaded:
            switch downloadState(for: model.id) {
            case .downloading(let progress):
                return "Downloading \(model.displayName) (\(Int(progress * 100))%)"
            case .notDownloaded:
                return "\(model.displayName) not downloaded"
            case .downloaded:
                return "\(model.displayName) not loaded"
            case .deleting:
                return "Deleting \(model.displayName)…"
            }
        }
    }

    // MARK: - Download / delete

    func download(_ modelID: String) {
        guard downloadState(for: modelID) == .notDownloaded else { return }
        lastError = nil
        downloadStates[modelID] = .downloading(progress: 0)

        // Called from the downloader's thread; hop to the main actor.
        let reportProgress: ProgressCallback = { [weak self] progress in
            let fraction = progress.fractionCompleted
            Task { @MainActor in self?.updateProgress(fraction, for: modelID) }
        }

        downloadTasks[modelID] = Task { [weak self] in
            do {
                if TranscriptionModel.model(withID: modelID)?.engine == .parakeet {
                    try await ParakeetEngine.download(to: Self.folder(for: modelID)) { fraction in
                        Task { @MainActor in self?.updateProgress(fraction, for: modelID) }
                    }
                } else {
                    _ = try await WhisperKit.download(
                        variant: modelID,
                        downloadBase: Self.downloadBase,
                        from: Self.repo,
                        progressCallback: reportProgress
                    )
                }
                // The Hub client returns normally (without throwing) when cancelled mid-snapshot.
                try Task.checkCancellation()
                // Launch-time detection looks for this marker, so a partial download never counts.
                let marker = Self.folder(for: modelID).appending(path: Self.completionMarker)
                try FileManager.default.createDirectory(
                    at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard FileManager.default.createFile(atPath: marker.path, contents: nil) else {
                    throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: marker.path])
                }
                self?.finishDownload(modelID)
            } catch {
                self?.failDownload(modelID, error: error)
            }
        }
    }

    func cancelDownload(_ modelID: String) {
        downloadTasks[modelID]?.cancel()
    }

    func delete(_ modelID: String) {
        guard deletionTasks[modelID] == nil else { return }
        if let task = downloadTasks[modelID] {
            // The cancelled download cleans up its own partial files.
            task.cancel()
            return
        }
        if loadedModelID == modelID || (selectedModelID == modelID && loadState == .loading) {
            unload()
        }
        // Core ML and tokenizer loading do not stop synchronously on cancellation.
        // Keep their input files intact until the pending load has finished.
        let pendingLoad = loadTask
        downloadStates[modelID] = .deleting
        deletionTasks[modelID] = Task { [weak self] in
            await pendingLoad?.value
            guard let self else { return }
            defer { self.deletionTasks[modelID] = nil }
            do {
                try self.removeFiles(for: modelID)
                self.downloadStates[modelID] = .notDownloaded
                self.lastError = nil
            } catch {
                let marker = Self.folder(for: modelID).appending(path: Self.completionMarker)
                self.downloadStates[modelID] = FileManager.default.fileExists(atPath: marker.path)
                    ? .downloaded : .notDownloaded
                self.lastError = "Could not delete model: \(error.localizedDescription)"
            }
        }
    }

    private func updateProgress(_ fraction: Double, for modelID: String) {
        guard case .downloading(let current) = downloadState(for: modelID) else { return }
        // Throttle UI updates to ~0.5% steps.
        if fraction - current >= 0.005 || fraction >= 1 {
            downloadStates[modelID] = .downloading(progress: min(fraction, 1))
        }
    }

    private func finishDownload(_ modelID: String) {
        downloadTasks[modelID] = nil
        downloadStates[modelID] = .downloaded
        if modelID == selectedModelID {
            loadSelectedModel()
        }
    }

    private func failDownload(_ modelID: String, error: Error) {
        downloadTasks[modelID] = nil
        downloadStates[modelID] = .notDownloaded
        // Don't leave half-downloaded files around.
        try? removeFiles(for: modelID)
        if !(error is CancellationError) {
            lastError = "Download failed: \(error.localizedDescription)"
        }
    }

    private func removeFiles(for modelID: String) throws {
        let fileManager = FileManager.default
        let isParakeet = TranscriptionModel.model(withID: modelID)?.engine == .parakeet
        let folder = isParakeet ? Self.parakeetRoot : Self.folder(for: modelID)
        if fileManager.fileExists(atPath: folder.path) {
            try fileManager.removeItem(at: folder)
        }
        // Per-file download metadata written by the Hub client.
        let metadata = Self.repoFolder.appending(path: ".cache/huggingface/download/\(modelID)")
        try? fileManager.removeItem(at: metadata)
    }

    private func refreshDownloadStates() {
        for model in TranscriptionModel.all {
            let marker = Self.folder(for: model.id).appending(path: Self.completionMarker)
            downloadStates[model.id] = FileManager.default.fileExists(atPath: marker.path) ? .downloaded : .notDownloaded
        }
    }

    // MARK: - Loading

    private func loadSelectedModel() {
        let modelID = selectedModelID
        if loadedModelID == modelID, whisperKit != nil || parakeet != nil { return }

        let pendingLoad = loadTask
        unload()
        guard downloadState(for: modelID) == .downloaded else { return }

        loadState = .loading
        let folder = Self.folder(for: modelID)
        let compute = selectedModel?.usesGPU == true
            ? ModelComputeOptions(audioEncoderCompute: .cpuAndGPU, textDecoderCompute: .cpuAndGPU)
            : ModelComputeOptions()
        loadTask = Task { [weak self] in
            // The Hub's tokenizer fetch is unstructured and survives cancellation.
            // Drain the previous load before starting another writer to the same cache.
            await pendingLoad?.value
            guard !Task.isCancelled else { return }
            if TranscriptionModel.model(withID: modelID)?.engine == .parakeet {
                do {
                    let engine = try await ParakeetEngine.load(from: folder)
                    guard !Task.isCancelled else { return }
                    self?.didLoad(parakeet: engine, modelID: modelID)
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.loadState = .failed(error.localizedDescription)
                }
                return
            }
            do {
                let config = WhisperKitConfig(
                    model: modelID,
                    downloadBase: Self.downloadBase,
                    modelFolder: folder.path,
                    // Tokenizer is fetched from the Hub on first load and cached here.
                    tokenizerFolder: Self.downloadBase,
                    computeOptions: compute,
                    verbose: true,
                    logLevel: .error,
                    prewarm: false,
                    load: true,
                    download: false
                )
                let kit = try await WhisperKit(config)
                guard !Task.isCancelled else { return }
                self?.didLoad(kit, modelID: modelID)
            } catch {
                guard !Task.isCancelled else { return }
                self?.loadState = .failed(error.localizedDescription)
            }
        }
    }

    private func didLoad(parakeet engine: ParakeetEngine, modelID: String) {
        guard modelID == selectedModelID else { return }
        parakeet = engine
        loadedModelID = modelID
        loadState = .loaded
        isReady = true
    }

    private func didLoad(_ kit: WhisperKit, modelID: String) {
        guard modelID == selectedModelID else { return }
        whisperKit = kit
        loadedModelID = modelID
        loadState = .loaded
        isReady = true
    }

    private func unload() {
        loadTask?.cancel()
        // Retain the handle so the next load/delete can await cancellation cleanup.
        whisperKit = nil
        parakeet = nil
        loadedModelID = nil
        loadState = .unloaded
        isReady = false
    }

    /// Retry loading the selected model (e.g. after a failure).
    func reloadSelectedModel() {
        unload()
        loadSelectedModel()
    }

    // MARK: - Transcription

    /// Transcribes 16 kHz mono samples and returns trimmed text.
    func transcribe(_ samples: [Float]) async throws -> String {
        guard isReady, let model = loadedModelID.flatMap(TranscriptionModel.model(withID:))
        else { throw TranscriptionError.modelNotReady }
        guard !samples.isEmpty else { return "" }

        if let parakeet {
            return Self.clean(try await parakeet.transcribe(samples))
        }
        guard let kit = whisperKit else { throw TranscriptionError.modelNotReady }

        let language = model.isMultilingual ? languageCode : "en"
        let options = DecodingOptions(
            task: .transcribe,
            language: language,
            usePrefillPrompt: true,
            // With a prefill prompt and no language, WhisperKit would assume English unless asked to detect.
            detectLanguage: language == nil,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            // Finished recordings can be shorter than WhisperKit's default 1s cutoff.
            // Sequential windows also propagate errors instead of dropping failed VAD chunks.
            windowClipTime: 0
        )

        let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
        return results
            .flatMap(\.segments)
            .map { Self.clean($0.text) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Strips whitespace and Whisper's non-speech markers such as "[BLANK_AUDIO]".
    private static func clean(_ text: String) -> String {
        text
            .replacingOccurrences(of: "[BLANK_AUDIO]", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
