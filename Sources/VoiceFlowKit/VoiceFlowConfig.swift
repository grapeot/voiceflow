import Foundation

/// Configuration for `VoiceFlowClient`. Pass a fresh config any time the
/// underlying settings (endpoint, token, language/prompt/terms) change;
/// the next session/transcribe call picks it up.
public struct VoiceFlowConfig: Sendable {
    public var endpoint: URL
    public var tokenProvider: @Sendable () async throws -> String
    public var model: String
    /// Optional BCP-47 language hint, e.g. "en", "zh".
    public var language: String?
    /// Optional context prompt for the transcription model.
    public var prompt: String?
    /// Domain-specific terms the recognizer should preserve.
    public var terms: [String]
    /// OSLog subsystem the kit uses for transport-level events.
    /// Default `nil` means use the bundle identifier or a built-in fallback.
    public var loggerSubsystem: String?

    public init(
        endpoint: URL = VoiceFlowConfig.defaultEndpoint,
        tokenProvider: @escaping @Sendable () async throws -> String,
        model: String = VoiceFlowConfig.defaultModel,
        language: String? = nil,
        prompt: String? = nil,
        terms: [String] = [],
        loggerSubsystem: String? = nil
    ) {
        self.endpoint = endpoint
        self.tokenProvider = tokenProvider
        self.model = model
        self.language = language
        self.prompt = prompt
        self.terms = terms
        self.loggerSubsystem = loggerSubsystem
    }

    public static let defaultEndpoint = URL(string: "https://space.ai-builders.com/backend")!
    public static let defaultModel = "gpt-realtime"
}
