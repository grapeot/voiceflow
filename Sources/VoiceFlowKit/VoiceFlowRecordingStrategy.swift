import Foundation

/// Selects the complete capture and transcription path for one recording.
public enum VoiceFlowRecordingStrategy: String, CaseIterable, Codable, Sendable {
    case openAIRealtime
    case gptLiveTranscribe
    case grokBatch
    /// Fully on-device transcription (Qwen3-ASR via CoreML). Records PCM
    /// WAV locally like the realtime strategies but never touches the
    /// network transport — the app layer transcribes the file itself.
    case localQwen3ASR

    /// Whether this strategy uses the ticket-based realtime WebSocket transport.
    public var usesRealtimeTransport: Bool {
        switch self {
        case .openAIRealtime, .gptLiveTranscribe:
            true
        case .grokBatch, .localQwen3ASR:
            false
        }
    }

    /// Whether this strategy records raw PCM16 WAV (as opposed to the
    /// AAC/M4A container used by Grok Batch). Local ASR needs lossless
    /// input for best recognition quality.
    public var recordsPCM: Bool {
        self != .grokBatch
    }

    func realtimeModel(configuredModel: String) -> String? {
        switch self {
        case .openAIRealtime:
            configuredModel
        case .gptLiveTranscribe:
            "gpt-live-transcribe"
        case .grokBatch, .localQwen3ASR:
            nil
        }
    }
}
