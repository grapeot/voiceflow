import Foundation
import Testing
@testable import VoiceFlowKit

/// Opt-in live integration test for the prompt-following path. Sends a
/// checked-in TTS WAV through `VoiceFlowClient.transcribe(audioFile:)`
/// to the real AI Builder backend and asserts the configured prompt
/// actually reaches the model — i.e. the wire format, library plumbing,
/// session creation, and model behavior all line up.
///
/// Gated by `VOICEFLOW_LIVE_WS=1` so unit-test runs don't burn API
/// credits. Driven by `scripts/test_live_integration.sh`, which also
/// loads `AI_BUILDER_TOKEN` / `AI_BUILDER_SPACE_ENDPOINT` from `.env`.
@Suite(.serialized)
struct LiveBackendPromptFollowingTests {

    @Test func promptInstructsModelToShoutInAllCaps() async throws {
        guard let credentials = LiveBackendCredentials.resolve() else {
            // Test is opt-in. Without env opt-in or `.env`, no-op so the
            // default `swift test` run stays green.
            return
        }

        let fixtureURL = try LiveBackendFixtures.allCapsTTSWav()

        let config = VoiceFlowConfig(
            endpoint: credentials.endpoint,
            tokenProvider: { credentials.token },
            prompt: "Transcribe every word in ALL CAPS. Example: THIS IS A TEST.",
            terms: []
        )
        let client = VoiceFlowClient(config: config)

        let result = try await client.transcribe(audioFile: fixtureURL)
        let transcript = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!transcript.isEmpty, "Live transcript came back empty — backend or wiring broken")

        // Model behavior isn't deterministic, so we don't require the full
        // sentence to be uppercased. Counting whole-word uppercase tokens
        // is the same shape of assertion the user validated during PR 2.
        let words = transcript
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
            .filter { $0.count >= 2 }
        let uppercaseWords = words.filter { word in
            word.allSatisfy { $0.isUppercase }
        }
        #expect(
            uppercaseWords.count >= 2,
            "Expected prompt to push model toward ALL CAPS, got transcript: \(transcript)"
        )
    }
}

/// Minimal credential resolver scoped to kit tests. Mirrors the app-target
/// `LiveIntegrationTestSupport` so PR 4 stays self-contained inside the
/// SPM test target rather than reaching back into the host app.
enum LiveBackendCredentials {
    struct Resolved {
        let token: String
        let endpoint: URL
    }

    static func resolve() -> Resolved? {
        let environment = ProcessInfo.processInfo.environment
        guard environment["VOICEFLOW_LIVE_WS"] == "1" else { return nil }

        let token = firstNonPlaceholder(
            environment["AI_BUILDER_TOKEN"],
            environment["VOICEFLOW_AI_BUILDER_TOKEN"]
        )
        guard let token else { return nil }

        let endpointString = environment["AI_BUILDER_SPACE_ENDPOINT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let endpoint = endpointString.isEmpty
            ? VoiceFlowConfig.defaultEndpoint
            : URL(string: endpointString) ?? VoiceFlowConfig.defaultEndpoint
        return Resolved(token: token, endpoint: endpoint)
    }

    private static func firstNonPlaceholder(_ candidates: String?...) -> String? {
        for candidate in candidates {
            guard let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty,
                  trimmed != "replace-with-your-real-token" else { continue }
            return trimmed
        }
        return nil
    }
}

enum LiveBackendFixtures {
    enum Error: Swift.Error, CustomStringConvertible {
        case fixtureMissing(name: String)

        var description: String {
            switch self {
            case .fixtureMissing(let name):
                return "Live fixture '\(name)' is missing from the test bundle. " +
                "Regenerate via Tests/VoiceFlowKitTests/Fixtures/regenerate.sh."
            }
        }
    }

    static func allCapsTTSWav() throws -> URL {
        guard let url = Bundle.module.url(forResource: "tts_all_caps_24k", withExtension: "wav") else {
            throw Error.fixtureMissing(name: "tts_all_caps_24k.wav")
        }
        return url
    }
}
