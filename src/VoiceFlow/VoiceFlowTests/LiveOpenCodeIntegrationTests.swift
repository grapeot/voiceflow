import Foundation
import Testing
@testable import VoiceFlow

/// Opt-in live OpenCode "send transcript" test against a real OpenCode server.
///
/// Disabled by default. Enable by setting `OPENCODE_LIVE=1` (and providing
/// `OPENCODE_BASE_URL` / `OPENCODE_USERNAME` / `OPENCODE_PASSWORD` via the
/// environment or a gitignored `.env` at the repo root). When disabled the
/// tests resolve no credentials and return immediately, so the default
/// `./scripts/test_unit.sh` run stays green and never touches the network.
///
/// Verified wire protocol (local server):
/// - POST `{base}/session` (Basic auth, body `{}`) -> 200 `{ "id": ... }`
/// - POST `{base}/session/{id}/prompt_async` (Basic auth) -> 204
/// - GET  `{base}/session/{id}/message` (Basic auth) -> 200, array where a
///   successful submission shows an `info.role == "user"` item whose joined
///   `parts[].text` equals the sent transcript.
@Suite(.serialized)
struct LiveOpenCodeIntegrationTests {
    @Test func liveSendTranscriptPersistsUserMessage() async throws {
        guard let credentials = LiveIntegrationTestSupport.resolveOpenCodeCredentials() else {
            return
        }

        let marker = ProcessInfo.processInfo.environment["VOICEFLOW_LIVE_E2E_MARKER"] ?? UUID().uuidString
        let transcript = "VoiceFlow live e2e test \(marker)"
        let client = OpenCodeClient()

        // sendTranscript now creates a session, posts the prompt, and reads the
        // session back until the user message lands. If the agent were wrong (the
        // original silent-failure bug) this would throw .messageNotPersisted.
        try await client.sendTranscript(
            transcript,
            serverURL: credentials.baseURL,
            username: credentials.username,
            password: credentials.password
        )

        // Independently confirm the job is really there: create a fresh session,
        // submit, then GET /message and assert the [user] message is present. This
        // mirrors the read-back the production path performs, end to end.
        let sessionID = try await createSession(credentials: credentials)
        try await sendPromptAsync(transcript, sessionID: sessionID, credentials: credentials)

        let userTexts = try await pollForUserMessages(sessionID: sessionID, credentials: credentials)
        #expect(
            userTexts.contains(transcript),
            "Expected a [user] message with the sent transcript in session \(sessionID); saw: \(userTexts)"
        )
    }

    // MARK: - Direct protocol helpers (independent of the production client)

    private func authHeader(_ credentials: LiveIntegrationTestSupport.OpenCodeCredentials) -> String {
        let raw = "\(credentials.username):\(credentials.password)"
        return "Basic \(Data(raw.utf8).base64EncodedString())"
    }

    private func baseURL(_ credentials: LiveIntegrationTestSupport.OpenCodeCredentials) throws -> URL {
        var trimmed = credentials.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let url = URL(string: trimmed) else {
            throw LiveIntegrationTestError.connectionFailed("Invalid OPENCODE_BASE_URL: \(credentials.baseURL)")
        }
        return url
    }

    private func createSession(credentials: LiveIntegrationTestSupport.OpenCodeCredentials) async throws -> String {
        let url = try baseURL(credentials).appending(path: "session")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(authHeader(credentials), forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [:] as [String: String])
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw LiveIntegrationTestError.connectionFailed("createSession returned non-200")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String else {
            throw LiveIntegrationTestError.connectionFailed("createSession response missing id")
        }
        return id
    }

    private func sendPromptAsync(
        _ text: String,
        sessionID: String,
        credentials: LiveIntegrationTestSupport.OpenCodeCredentials
    ) async throws {
        let url = try baseURL(credentials).appending(path: "session").appending(path: sessionID).appending(path: "prompt_async")
        let payload: [String: Any] = [
            "parts": [["type": "text", "text": text]],
            "model": ["modelID": OpenCodeClient.defaultModelID, "providerID": OpenCodeClient.defaultProviderID],
            "agent": OpenCodeClient.defaultAgent
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(authHeader(credentials), forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.timeoutInterval = 60

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 204 else {
            throw LiveIntegrationTestError.connectionFailed("prompt_async did not return 204")
        }
    }

    private func pollForUserMessages(
        sessionID: String,
        credentials: LiveIntegrationTestSupport.OpenCodeCredentials,
        maxAttempts: Int = 10,
        retryDelay: Duration = .milliseconds(500)
    ) async throws -> [String] {
        let url = try baseURL(credentials).appending(path: "session").appending(path: sessionID).appending(path: "message")
        var lastSeen: [String] = []
        for attempt in 0..<maxAttempts {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue(authHeader(credentials), forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 10

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw LiveIntegrationTestError.connectionFailed("GET /message returned non-200")
            }
            if let messages = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                let userTexts = messages.compactMap { item -> String? in
                    let role = (item["info"] as? [String: Any])?["role"] as? String
                    guard role == "user" else { return nil }
                    guard let parts = item["parts"] as? [[String: Any]] else { return nil }
                    let texts = parts.compactMap { $0["text"] as? String ?? $0["content"] as? String }
                    return texts.isEmpty ? nil : texts.joined()
                }
                lastSeen = userTexts
                if !userTexts.isEmpty {
                    return userTexts
                }
            }
            if attempt < maxAttempts - 1 {
                try? await Task.sleep(for: retryDelay)
            }
        }
        return lastSeen
    }
}
