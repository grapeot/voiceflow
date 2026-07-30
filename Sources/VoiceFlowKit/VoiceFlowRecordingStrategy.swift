import Foundation

/// Selects the complete capture and transcription path for one recording.
public enum VoiceFlowRecordingStrategy: String, CaseIterable, Codable, Sendable {
    case openAIRealtime
    case grokBatch
}
