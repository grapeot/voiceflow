import Foundation

/// Configuration for `VoiceFlowClient`. Pass a fresh config any time the
/// underlying settings (endpoint, token, language/prompt/terms) change;
/// the next session/transcribe call picks it up.
public struct VoiceFlowConfig: Sendable {
    public var endpoint: URL
    public var tokenProvider: @Sendable () async throws -> String
    public var model: String
    /// Optional context prompt for the transcription model. The
    /// backend treats this as prompt concatenation, so the host is
    /// free to embed any context — including language hints
    /// (e.g. "User is speaking Mandarin Chinese") — directly in the
    /// prompt string. The kit deliberately does not expose a separate
    /// `language` field to avoid duplicating a knob the backend
    /// doesn't have.
    public var prompt: String?
    /// Domain-specific terms the recognizer should preserve. Stored
    /// as `[String]` here even though the wire format may concatenate
    /// them into the prompt — keeps the host API ergonomic.
    public var terms: [String]
    /// OSLog subsystem the kit uses for transport-level events.
    /// Default `nil` means use the bundle identifier or a built-in fallback.
    public var loggerSubsystem: String?

    public init(
        endpoint: URL = VoiceFlowConfig.defaultEndpoint,
        tokenProvider: @escaping @Sendable () async throws -> String,
        model: String = VoiceFlowConfig.defaultModel,
        prompt: String? = nil,
        terms: [String] = [],
        loggerSubsystem: String? = nil
    ) {
        self.endpoint = endpoint
        self.tokenProvider = tokenProvider
        self.model = model
        self.prompt = prompt
        self.terms = terms
        self.loggerSubsystem = loggerSubsystem
    }

    public static let defaultEndpoint = URL(string: "https://space.ai-builders.com/backend")!
    public static let defaultModel = "gpt-realtime"
}
