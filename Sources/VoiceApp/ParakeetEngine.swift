import FluidAudio
import Foundation

/// NVIDIA Parakeet TDT 0.6B v3 via FluidAudio (Core ML). Kept in its own file, behind this
/// wrapper, so FluidAudio's type names don't clash with WhisperKit's in `ModelManager`.
final class ParakeetEngine: Sendable {
    private let manager: AsrManager

    private init(manager: AsrManager) {
        self.manager = manager
    }

    /// FluidAudio stores the repo in `<parent of directory>/<repo folder>`, so pass a folder whose
    /// name is the repo folder name to keep everything in one place.
    static func download(to directory: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let tracker = StageTracker()
        try await AsrModels.download(to: directory, version: .v3) { update in
            progress(tracker.overall(update.fractionCompleted))
        }
    }

    /// FluidAudio fetches the four sub-models one after another and restarts `fractionCompleted`
    /// for each. The first stage downloads almost all files, so it gets most of the bar.
    private final class StageTracker: @unchecked Sendable {
        private static let weights = [0.85, 0.05, 0.05, 0.05]
        private let lock = NSLock()
        private var stage = 0
        private var last = 0.0

        func overall(_ fraction: Double) -> Double {
            lock.withLock {
                if fraction + 0.2 < last, stage < Self.weights.count - 1 { stage += 1 }
                last = fraction
                let done = Self.weights.prefix(stage).reduce(0, +)
                return min(done + Self.weights[stage] * fraction, 1)
            }
        }
    }

    static func load(from directory: URL) async throws -> ParakeetEngine {
        let models = try await AsrModels.load(from: directory, version: .v3)
        let manager = AsrManager()
        try await manager.loadModels(models)
        return ParakeetEngine(manager: manager)
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        // The encoder works on fixed windows; pad very short clips to 1 s of audio.
        var audio = samples
        if audio.count < 16_000 {
            audio += [Float](repeating: 0, count: 16_000 - audio.count)
        }
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        return try await manager.transcribe(audio, decoderState: &state).text
    }
}
