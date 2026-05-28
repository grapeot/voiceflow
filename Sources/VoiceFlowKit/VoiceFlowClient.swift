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

    /// Internal initializer. The host's own test target can reach this
    /// via `@testable import VoiceFlowKit` and inject a custom mock
    /// conforming to the internal transcribing protocol — handy for
    /// scripting precise event sequences in unit tests. Production app
    /// code that just needs an offline client (UI test launch mode,
    /// SwiftUI previews) should use `makeStub(...)` instead.
    init(config: VoiceFlowConfig, transcriber: any RealtimeTranscribing) {
        self.config = config
        self.transcriber = transcriber
    }

    /// Offline stub client. Does not open a WebSocket; `startSession`
    /// returns a session whose `commitAndStop` resolves to the canned
    /// `liveTranscript` after emitting a `connected → idle` event
    /// sequence. `transcribe(audioFile:)` returns `bulkTranscript`
    /// (falls back to `liveTranscript` if unset).
    ///
    /// Use this in:
    /// - App UI test launch modes (`-uiTestMode` style flags) where
    ///   the host needs a `VoiceFlowClient` that behaves end-to-end
    ///   without network access.
    /// - SwiftUI previews and design-time scaffolding.
    ///
    /// Tokens in `config.tokenProvider` are ignored; the stub does not
    /// authenticate. The returned client is otherwise indistinguishable
    /// from a production one — the same facade types flow out, the
    /// same lifecycle methods work.
    public static func makeStub(
        config: VoiceFlowConfig = VoiceFlowConfig(tokenProvider: { "stub-token" }),
        liveTranscript: String = "Mock transcription",
        bulkTranscript: String? = nil
    ) -> VoiceFlowClient {
        let transcriber = MockRealtimeTranscriptionClient(
            liveResult: .success(liveTranscript),
            bulkResult: .success(bulkTranscript ?? liveTranscript)
        )
        return VoiceFlowClient(config: config, transcriber: transcriber)
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
                context: RealtimeSessionContext(prompt: config.prompt, terms: config.terms),
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
                context: RealtimeSessionContext(prompt: config.prompt, terms: config.terms),
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
