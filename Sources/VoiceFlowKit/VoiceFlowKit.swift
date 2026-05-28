import Foundation

/// Module marker. Real public API lives in
/// `VoiceFlowClient.swift`, `VoiceFlowSession.swift`,
/// `VoiceFlowMicrophone.swift`, `VoiceFlowConfig.swift`,
/// `VoiceFlowError.swift`, and `StreamCaption.swift`.
///
/// Integration guide for AI agents who want to add voice input to a host
/// iOS / visionOS app: `skills/adding_voice_input_with_voiceflowkit.md`.
public enum VoiceFlowKit {
    public static let version = "0.1.0-dev"
}
