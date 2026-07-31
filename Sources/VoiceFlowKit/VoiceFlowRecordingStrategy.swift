import Foundation

/// Selects the complete capture and transcription path for one recording.
public enum VoiceFlowRecordingStrategy: String, CaseIterable, Codable, Sendable {
    case openAIRealtime
    case gptLiveTranscribe
    case grokBatch

    /// Whether this strategy uses the ticket-based realtime WebSocket transport.
    public var usesRealtimeTransport: Bool {
        self != .grokBatch
    }

    func realtimeModel(configuredModel: String) -> String? {
        switch self {
        case .openAIRealtime:
            configuredModel
        case .gptLiveTranscribe:
            "gpt-live-transcribe"
        case .grokBatch:
            nil
        }
    }
}
