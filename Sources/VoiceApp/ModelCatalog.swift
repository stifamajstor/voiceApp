import Foundation

/// A speech-to-text model offered by the app. `id` is the WhisperKit variant, i.e. the folder
/// name inside the Hugging Face repo `argmaxinc/whisperkit-coreml`.
struct TranscriptionModel: Identifiable, Hashable {
    let id: String
    let displayName: String
    let approximateSize: String
    let notes: String
    let isMultilingual: Bool
    /// Large models run on the GPU: compiling them for the Neural Engine takes 30+ minutes on
    /// M1-class chips (ANECompilerService), while GPU loading takes seconds.
    var usesGPU = false
    var engine: Engine = .whisperKit

    enum Engine {
        case whisperKit
        /// NVIDIA Parakeet via FluidAudio; detects the language itself (25 European languages).
        case parakeet
    }

    static let all: [TranscriptionModel] = [
        TranscriptionModel(
            id: "openai_whisper-tiny.en",
            displayName: "Whisper Tiny (EN)",
            approximateSize: "~150 MB",
            notes: "Fastest, English only",
            isMultilingual: false
        ),
        TranscriptionModel(
            id: "openai_whisper-base",
            displayName: "Whisper Base",
            approximateSize: "~145 MB",
            notes: "Fast, multilingual",
            isMultilingual: true
        ),
        TranscriptionModel(
            id: "openai_whisper-small",
            displayName: "Whisper Small",
            approximateSize: "~485 MB",
            notes: "Good balance of speed and accuracy",
            isMultilingual: true
        ),
        TranscriptionModel(
            id: "distil-whisper_distil-large-v3_turbo_600MB",
            displayName: "Distil-Whisper Large v3 Turbo",
            approximateSize: "~610 MB",
            notes: "English only, fast and accurate",
            isMultilingual: false,
            usesGPU: true
        ),
        TranscriptionModel(
            id: "openai_whisper-large-v3-v20240930_turbo_632MB",
            displayName: "Whisper Large v3 Turbo",
            approximateSize: "~645 MB",
            notes: "Best quality, multilingual (recommended)",
            isMultilingual: true,
            usesGPU: true
        ),
        TranscriptionModel(
            id: "parakeet-tdt-0.6b-v3",
            displayName: "NVIDIA Parakeet TDT 0.6B v3",
            approximateSize: "~480 MB",
            notes: "Very fast and accurate, 25 European languages (auto-detected)",
            isMultilingual: true,
            engine: .parakeet
        ),
    ]

    static let defaultID = "openai_whisper-large-v3-v20240930_turbo_632MB"

    static func model(withID id: String) -> TranscriptionModel? {
        all.first { $0.id == id }
    }
}

/// Spoken language hint passed to Whisper. `code == nil` means auto-detect.
struct TranscriptionLanguage: Identifiable, Hashable {
    let code: String?
    let name: String

    var id: String { code ?? "auto" }

    static let all: [TranscriptionLanguage] = [
        TranscriptionLanguage(code: nil, name: "Auto-detect"),
        TranscriptionLanguage(code: "en", name: "English"),
        TranscriptionLanguage(code: "de", name: "German"),
        TranscriptionLanguage(code: "hr", name: "Croatian"),
        TranscriptionLanguage(code: "bs", name: "Bosnian"),
        TranscriptionLanguage(code: "sr", name: "Serbian"),
        TranscriptionLanguage(code: "sl", name: "Slovenian"),
        TranscriptionLanguage(code: "fr", name: "French"),
        TranscriptionLanguage(code: "es", name: "Spanish"),
        TranscriptionLanguage(code: "it", name: "Italian"),
        TranscriptionLanguage(code: "pt", name: "Portuguese"),
        TranscriptionLanguage(code: "nl", name: "Dutch"),
        TranscriptionLanguage(code: "pl", name: "Polish"),
        TranscriptionLanguage(code: "ru", name: "Russian"),
        TranscriptionLanguage(code: "uk", name: "Ukrainian"),
    ]
}
