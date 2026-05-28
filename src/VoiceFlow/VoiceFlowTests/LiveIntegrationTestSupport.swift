import Foundation
@testable import VoiceFlowKit
@testable import VoiceFlow

/// Helpers for opt-in live WebSocket integration tests against AI Builder Space.
///
/// Enabled only when `VOICEFLOW_LIVE_WS=1`. Credentials come from process environment
/// (set by `scripts/test_live_integration.sh`) or from `$VOICEFLOW_REPO_ROOT/.env`.
enum LiveIntegrationTestSupport {
    struct Credentials: Sendable {
        let token: String
        let endpoint: String
    }

    static var isEnabled: Bool {
        if ProcessInfo.processInfo.environment["VOICEFLOW_LIVE_WS"] == "1" {
            return true
        }
        guard let root = repositoryRoot() else { return false }
        let marker = root.appendingPathComponent(".voiceflow/live-ws-opt-in")
        return FileManager.default.fileExists(atPath: marker.path)
    }

    static func resolveCredentials() throws -> Credentials? {
        guard isEnabled else { return nil }

        if let fromEnvironment = credentialsFromProcessEnvironment() {
            return fromEnvironment
        }

        if let root = repositoryRoot() {
            let dotEnvURL = root.appendingPathComponent(".env")
            if let fromDotEnv = credentialsFromDotEnv(at: dotEnvURL) {
                return fromDotEnv
            }
        }

        return nil
    }

    private static func repositoryRoot() -> URL? {
        if let envRoot = ProcessInfo.processInfo.environment["VOICEFLOW_REPO_ROOT"],
           !envRoot.isEmpty {
            return URL(fileURLWithPath: envRoot)
        }

        var candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<6 {
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent(".env.example").path) {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }
        return nil
    }

    static func waitUntilConnected(
        session: RealtimeLiveTranscriptionSession,
        timeoutSeconds: TimeInterval = 15
    ) async throws -> RealtimeConnectionPhase {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            let phase = await session.connectionPhase
            if phase == .connected || phase == .generating {
                return phase
            }
            if phase == .disconnected {
                throw LiveIntegrationTestError.connectionFailed("WebSocket disconnected before connected status")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw LiveIntegrationTestError.connectionFailed("Timed out waiting for connected status")
    }

    static func waitForEvent(
        _ predicate: @escaping (RealtimeTranscriptEvent) -> Bool,
        in events: [RealtimeTranscriptEvent],
        pollIntervalMs: UInt64 = 100,
        timeoutSeconds: TimeInterval = 15
    ) async throws -> RealtimeTranscriptEvent {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if let match = events.first(where: predicate) {
                return match
            }
            try await Task.sleep(for: .milliseconds(pollIntervalMs))
        }
        throw LiveIntegrationTestError.connectionFailed("Timed out waiting for expected server event")
    }

    static func waitForEvent(
        _ predicate: @escaping (RealtimeTranscriptEvent) -> Bool,
        from collector: EventCollector,
        pollIntervalMs: UInt64 = 100,
        timeoutSeconds: TimeInterval = 15
    ) async throws -> RealtimeTranscriptEvent {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            let snapshot = await collector.snapshot()
            if let match = snapshot.first(where: predicate) {
                return match
            }
            try await Task.sleep(for: .milliseconds(pollIntervalMs))
        }
        throw LiveIntegrationTestError.connectionFailed("Timed out waiting for expected server event")
    }

    private static func credentialsFromProcessEnvironment() -> Credentials? {
        let environment = ProcessInfo.processInfo.environment
        guard let token = firstNonPlaceholderToken(
            environment["AI_BUILDER_TOKEN"],
            environment["VOICEFLOW_AI_BUILDER_TOKEN"]
        ) else {
            return nil
        }

        let rawEndpoint = environment["AI_BUILDER_SPACE_ENDPOINT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let endpoint = rawEndpoint.isEmpty ? defaultEndpoint : rawEndpoint
        return Credentials(token: token, endpoint: endpoint)
    }

    private static func credentialsFromDotEnv(at url: URL) -> Credentials? {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let values = parseDotEnv(contents)
        guard let token = firstNonPlaceholderToken(
            values["AI_BUILDER_TOKEN"],
            values["VOICEFLOW_AI_BUILDER_TOKEN"]
        ) else {
            return nil
        }

        let rawEndpoint = values["AI_BUILDER_SPACE_ENDPOINT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let endpoint = rawEndpoint.isEmpty ? defaultEndpoint : rawEndpoint
        return Credentials(token: token, endpoint: endpoint)
    }

    private static func parseDotEnv(_ contents: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in contents.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            values[parts[0].trimmingCharacters(in: .whitespacesAndNewlines)] =
                parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return values
    }

    private static func firstNonPlaceholderToken(_ candidates: String?...) -> String? {
        for candidate in candidates {
            guard let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty,
                  trimmed != placeholderToken else {
                continue
            }
            return trimmed
        }
        return nil
    }

    private static let defaultEndpoint = "https://space.ai-builders.com/backend"
    private static let placeholderToken = "replace-with-your-real-token"
}

enum LiveIntegrationTestError: Error, CustomStringConvertible {
    case connectionFailed(String)

    var description: String {
        switch self {
        case .connectionFailed(let message):
            return message
        }
    }
}

actor EventCollector {
    private var events: [RealtimeTranscriptEvent] = []

    func append(_ event: RealtimeTranscriptEvent) {
        events.append(event)
    }

    func snapshot() -> [RealtimeTranscriptEvent] {
        events
    }
}
