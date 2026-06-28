import Foundation

#if os(iOS) || os(visionOS)
@preconcurrency import AVFoundation

/// Public microphone capture facade. Wraps the internal `AudioRecorder`,
/// streams PCM16/24kHz/mono chunks through `onPCMChunk`, exposes a
/// smoothed audio level via `audioLevel`, and can optionally persist
/// the recorded PCM to a WAV file (used by VoiceFlow's resend feature).
///
/// Available on iOS and visionOS. macOS targets get a compile-time
/// error if they import this type — keep mic logic conditional in
/// cross-platform hosts.
@MainActor
public final class VoiceFlowMicrophone {
    private let recorder: AudioRecorder
    private let levelContinuation: AsyncStream<Float>.Continuation
    /// 0..1 smoothed audio level. Cold stream — host must iterate
    /// to drive a waveform; no-consumer drops samples cheaply.
    public let audioLevel: AsyncStream<Float>

    /// Storage URL set by `start(persistTo:)`. Available after `stopRecording`.
    public private(set) var recordingFileURL: URL?

    public init() {
        self.recorder = AudioRecorder()
        var capturedContinuation: AsyncStream<Float>.Continuation!
        self.audioLevel = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            capturedContinuation = continuation
        }
        self.levelContinuation = capturedContinuation
    }

    public func requestPermission() async -> Bool {
        await recorder.requestPermission()
    }

    /// Start capturing. `onPCMChunk` is called on a non-main actor with
    /// each PCM16/24kHz/mono chunk. Optionally persist PCM to disk for
    /// later replay/export — VoiceFlow uses this for resend.
    public func start(onPCMChunk: @escaping @Sendable (Data) -> Void) async throws {
        let levelSmoother = LevelSmoother()
        let continuation = levelContinuation
        try await recorder.startRecording { [weak self] chunk in
            guard self != nil else { return }
            let raw = VoiceFlowAudioMetering.normalizedLevel(fromPCM16LE: chunk)
            Task {
                let smoothed = await levelSmoother.advance(raw)
                continuation.yield(smoothed)
            }
            onPCMChunk(chunk)
        }
    }

    /// Stop capturing. Returns the persisted WAV file URL if `start`
    /// recorded one; otherwise returns nil. Underlying recorder is
    /// always reset.
    public func stop() async throws -> URL? {
        do {
            let url = try await recorder.stopRecording()
            recordingFileURL = url
            return url
        } catch {
            // Stopping with no active recording is benign — return nil.
            return nil
        }
    }

    /// Discard any in-progress recording. Idempotent.
    public func discard() {
        recorder.discardRecording()
        recordingFileURL = nil
    }
}

/// Actor for EMA-smoothed audio level. 30% new sample / 70% carried.
/// Matches the original AppState-based smoothing the VoiceFlow app
/// shipped with — moving the math here keeps Swift 6 concurrency clean.
private actor LevelSmoother {
    private var current: Float = 0
    func advance(_ raw: Float) -> Float {
        current = current * 0.7 + raw * 0.3
        return current
    }
}
#endif

/// Public helper for hosts who want to compute the same audio level
/// VoiceFlowKit uses internally — e.g. when feeding the microphone
/// from an existing AVAudioEngine instead of `VoiceFlowMicrophone`.
public enum VoiceFlowAudioMetering: Sendable {
    /// Compute raw RMS (0..1) from a PCM16 little-endian chunk.
    /// Unlike `normalizedLevel`, this is the untransformed RMS —
    /// useful for signal-quality detection where dB remapping would
    /// compress the low end.
    public static func rmsLevel(fromPCM16LE data: Data) -> Float {
        let sampleCount = data.count / 2
        guard sampleCount > 0 else { return 0 }

        let sumSquares: Double = data.withUnsafeBytes { raw -> Double in
            guard let base = raw.baseAddress else { return 0 }
            var accumulator: Double = 0
            for i in 0..<sampleCount {
                let lo = Int16(base.load(fromByteOffset: i * 2,     as: UInt8.self))
                let hi = Int16(base.load(fromByteOffset: i * 2 + 1, as: UInt8.self))
                let raw = (hi << 8) | (lo & 0xFF)
                let sample = Double(raw) / 32768.0
                accumulator += sample * sample
            }
            return accumulator
        }

        return Float(sqrt(sumSquares / Double(sampleCount)))
    }

    /// Compute a 0..1 smoothed level from a PCM16 little-endian chunk
    /// using RMS → dB → linear remap → 0.9× tail. This matches what
    /// `VoiceFlowMicrophone.audioLevel` publishes, minus the EMA
    /// smoothing (the caller can apply that themselves if needed).
    public static func normalizedLevel(fromPCM16LE data: Data) -> Float {
        let sampleCount = data.count / 2
        guard sampleCount > 0 else { return 0 }

        let rms = Double(rmsLevel(fromPCM16LE: data))
        let dB = 20.0 * log10(max(rms, 1e-7))
        let minDB = -50.0
        let maxDB = -10.0
        let normalized = (dB - minDB) / (maxDB - minDB)
        let scaled = normalized * 0.9
        return Float(min(max(scaled, 0), 1))
    }
}
