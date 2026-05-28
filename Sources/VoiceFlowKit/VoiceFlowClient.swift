import Foundation

/// Public entry point for VoiceFlowKit. Holds the config (endpoint, token
/// provider, optional language/prompt/terms) and creates sessions.
///
/// Sessions are independent — you can start, stop, cancel, restart in
/// any order. The client itself is cheap; it's safe to construct one
/// per host-side controller or share a single instance.
///
/// VoiceFlowKit V0 wraps the internal `RealtimeTranscribing` implementation.
/// Tests can inject a custom transcriber via the `makeForTesting` factory.
public actor VoiceFlowClient {
    private var config: VoiceFlowConfig
    private let transcriber: any RealtimeTranscribing

    public init(config: VoiceFlowConfig) {
        self.config = config
        self.transcriber = RealtimeTranscriptionClient()
    }

    /// Test-only initializer. Hosts inject a mock conforming to the
    /// internal transcribing protocol. Not part of the SemVer-stable
    /// surface — kept `internal` to the kit; callers must reach in via
    /// `@testable import VoiceFlowKit`.
    init(config: VoiceFlowConfig, transcriber: any RealtimeTranscribing) {
        self.config = config
        self.transcriber = transcriber
    }

    /// Replace the entire config. Effective on the next call.
    public func updateConfig(_ config: VoiceFlowConfig) {
        self.config = config
    }

    /// Current config (read-only view for hosts that need to inspect).
    public func currentConfig() -> VoiceFlowConfig {
        config
    }

    /// One-shot transcription of an existing audio file (WAV/M4A).
    /// Internally feeds the PCM through the same realtime WS pipeline,
    /// gathers partial deltas, returns the final string.
    public func transcribe(
        audioFile: URL,
        onPartialTranscript: (@Sendable (String) -> Void)? = nil
    ) async throws -> TranscriptionResult {
        let token = try await currentToken()
        let pcmData: Data
        do {
            // For WAV files we extract PCM directly; for other formats
            // the host should pre-convert. V0 of the kit only supports
            // WAV input here — this matches what VoiceFlow's resend
            // path uses and OpenCode's one-shot path can adopt.
            pcmData = try PCM16WAVWriter.readPCM(from: audioFile)
        } catch {
            throw VoiceFlowError.audioConversionFailed
        }
        do {
            let text = try await transcriber.transcribeBulkPCM(
                pcmData: pcmData,
                baseURL: config.endpoint.absoluteString,
                token: token,
                model: config.model,
                onPartialTranscript: onPartialTranscript
            )
            return TranscriptionResult(text: text, requestID: UUID().uuidString)
        } catch let realtime as RealtimeTranscriptionError {
            throw VoiceFlowError(realtime)
        }
    }

    /// Start a realtime session. Host then pumps PCM chunks in,
    /// optionally pings, and finalizes with `commitAndStop`.
    public func startSession() async throws -> VoiceFlowSession {
        let token = try await currentToken()
        let bridge = SessionEventBridge()
        do {
            let live = try await transcriber.beginLiveSession(
                baseURL: config.endpoint.absoluteString,
                token: token,
                model: config.model,
                onEvent: { event in
                    bridge.emit(event)
                }
            )
            return VoiceFlowSession(underlying: live, eventBridge: bridge)
        } catch let realtime as RealtimeTranscriptionError {
            bridge.finish()
            throw VoiceFlowError(realtime)
        }
    }

    /// Verify endpoint reachability + token validity. Lightweight GET to
    /// the API summary endpoint. Throws on any failure.
    public func testConnection() async throws {
        let token = try await currentToken()
        do {
            let tester = AIBuilderClient()
            try await tester.testConnection(
                baseURL: config.endpoint.absoluteString,
                token: token
            )
        } catch {
            throw VoiceFlowError.underlying(String(describing: error))
        }
    }

    private func currentToken() async throws -> String {
        do {
            let token = try await config.tokenProvider()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { throw VoiceFlowError.missingToken }
            return token
        } catch let voiceFlowError as VoiceFlowError {
            throw voiceFlowError
        } catch {
            throw VoiceFlowError.missingToken
        }
    }
}

/// Result of a one-shot transcription.
public struct TranscriptionResult: Sendable, Equatable {
    public let text: String
    public let requestID: String

    public init(text: String, requestID: String) {
        self.text = text
        self.requestID = requestID
    }
}
