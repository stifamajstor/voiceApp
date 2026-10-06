import AVFoundation
import CoreAudio
import Foundation

/// Captures microphone audio and hands back 16 kHz mono Float32 samples (what Whisper expects).
///
/// A fresh `AVAudioEngine` is created per recording and torn down on `stop()`, so the mic (and the
/// orange indicator) is only active while recording, and device changes between recordings are
/// picked up automatically.
///
/// Call `start()` / `stop()` from the main actor only. The tap callback runs on an audio thread and
/// only touches a `CaptureSink`, which does its own locking.
@MainActor
final class AudioRecorder {
    enum RecorderError: LocalizedError {
        case permissionDenied
        case noInputDevice
        case alreadyRecording
        case converterUnavailable
        case engineFailed(String)

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Microphone access denied — enable it in System Settings"
            case .noInputDevice:
                return "No microphone found"
            case .alreadyRecording:
                return "Already recording"
            case .converterUnavailable:
                return "Unsupported microphone format"
            case .engineFailed(let reason):
                return "Couldn't start recording: \(reason)"
            }
        }
    }

    static let targetSampleRate: Double = 16_000

    /// Called (on the main actor) if the audio engine stops by itself mid-recording, e.g. the input
    /// device was unplugged. Samples captured so far are still returned by `stop()`.
    var onInterrupted: (() -> Void)?

    private var engine: AVAudioEngine?
    private var sink: CaptureSink?
    private var configObserver: NSObjectProtocol?

    var isRecording: Bool { engine != nil }

    func start() throws {
        guard engine == nil else { throw RecorderError.alreadyRecording }
        // Without authorization AVAudioEngine happily delivers silence, so check up front.
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw RecorderError.permissionDenied
        }
        // Touching `inputNode` with no input device can raise an uncatchable ObjC exception.
        guard Self.hasDefaultInputDevice() else { throw RecorderError.noInputDevice }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let hardwareFormat = input.outputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
            throw RecorderError.noInputDevice
        }

        let sink = try CaptureSink(inputFormat: hardwareFormat, targetSampleRate: Self.targetSampleRate)
        input.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat, block: sink.makeTapBlock())

        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw RecorderError.engineFailed(error.localizedDescription)
        }

        self.engine = engine
        self.sink = sink
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleConfigurationChange() }
        }
    }

    /// Stops capture, releases the engine and returns everything recorded (empty if not recording).
    @discardableResult
    func stop() -> [Float] {
        guard let engine, let sink else { return [] }
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        self.sink = nil
        return sink.finish()
    }

    private func handleConfigurationChange() {
        // The engine posts this on any hardware change; it only matters if it actually stopped.
        guard let engine, !engine.isRunning else { return }
        onInterrupted?()
    }

    private static func hasDefaultInputDevice() -> Bool {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        return status == noErr && deviceID != AudioObjectID(kAudioObjectUnknown)
    }
}

/// Receives buffers on the audio thread, downmixes to mono, resamples to the target rate and
/// accumulates the result. Deliberately not main-actor isolated.
private final class CaptureSink: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var finished = false

    // Only touched from the (serial) tap callback.
    private let monoFormat: AVAudioFormat
    private let converter: AVAudioConverter?
    private let targetRatio: Double
    private var monoBuffer: AVAudioPCMBuffer?
    private var outputBuffer: AVAudioPCMBuffer?
    private var loggedConversionError = false

    init(inputFormat: AVAudioFormat, targetSampleRate: Double) throws {
        guard
            let mono = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: inputFormat.sampleRate,
                channels: 1,
                interleaved: false
            ),
            let target = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: targetSampleRate,
                channels: 1,
                interleaved: false
            )
        else {
            throw AudioRecorder.RecorderError.converterUnavailable
        }
        monoFormat = mono
        targetRatio = targetSampleRate / inputFormat.sampleRate

        if inputFormat.sampleRate == targetSampleRate {
            converter = nil
        } else {
            guard let converter = AVAudioConverter(from: mono, to: target) else {
                throw AudioRecorder.RecorderError.converterUnavailable
            }
            // Streaming use: don't insert/discard priming frames at every start.
            converter.primeMethod = .none
            self.converter = converter
        }
    }

    func makeTapBlock() -> AVAudioNodeTapBlock {
        { [self] buffer, _ in process(buffer) }
    }

    func finish() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        finished = true
        let result = samples
        samples = []
        return result
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        guard frames > 0, let channels = buffer.floatChannelData else { return }

        // 1. Downmix to mono at the hardware rate.
        guard let mono = reusableBuffer(&monoBuffer, format: monoFormat, capacity: frames),
              let monoData = mono.floatChannelData?[0]
        else { return }

        let channelCount = Int(buffer.format.channelCount)
        let stride = buffer.stride // > 1 for interleaved buffers
        if channelCount == 1 && stride == 1 {
            monoData.update(from: channels[0], count: frames)
        } else {
            let scale = 1 / Float(channelCount)
            for i in 0..<frames {
                var sum: Float = 0
                for c in 0..<channelCount { sum += channels[c][i * stride] }
                monoData[i] = sum * scale
            }
        }
        mono.frameLength = AVAudioFrameCount(frames)

        // 2. Resample (if needed) and append.
        guard let converter else {
            append(UnsafeBufferPointer(start: monoData, count: frames))
            return
        }

        let capacity = Int(Double(frames) * targetRatio) + 64
        guard let out = reusableBuffer(&outputBuffer, format: converter.outputFormat, capacity: capacity),
              let outData = out.floatChannelData?[0]
        else { return }
        out.frameLength = 0

        var supplied = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return mono
        }

        if status == .error {
            if !loggedConversionError {
                loggedConversionError = true
                NSLog("VoiceApp: audio conversion failed: \(error?.localizedDescription ?? "unknown")")
            }
            return
        }
        append(UnsafeBufferPointer(start: outData, count: Int(out.frameLength)))
    }

    private func reusableBuffer(
        _ slot: inout AVAudioPCMBuffer?, format: AVAudioFormat, capacity: Int
    ) -> AVAudioPCMBuffer? {
        if let existing = slot, Int(existing.frameCapacity) >= capacity { return existing }
        let newBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(capacity, 8192)))
        slot = newBuffer
        return newBuffer
    }

    private func append(_ chunk: UnsafeBufferPointer<Float>) {
        guard chunk.count > 0 else { return }
        lock.lock()
        if !finished { samples.append(contentsOf: chunk) }
        lock.unlock()
    }
}
