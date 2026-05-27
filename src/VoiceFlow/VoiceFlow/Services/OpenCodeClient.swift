import Foundation

protocol OpenCodeSending {
    func sendTranscript(_ text: String, serverURL: String, username: String, password: String) async throws
    func testConnection(serverURL: String, username: String, password: String) async throws
}

enum OpenCodeClientError: Error, Equatable {
    case invalidURL
    case insecureRemoteURL
    case invalidResponse
    case sessionCreationFailed
    case promptSendFailed
}

extension OpenCodeClientError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "The server URL is invalid."
        case .insecureRemoteURL:
            "Remote servers must use HTTPS. HTTP is allowed only for localhost and Tailscale (*.ts.net) hosts."
        case .invalidResponse:
            "The server returned an unexpected response."
        case .sessionCreationFailed:
            "Could not reach the OpenCode server or authentication failed."
        case .promptSendFailed:
            "The server rejected the transcript prompt."
        }
    }
}

struct OpenCodeClient: OpenCodeSending {
    static let defaultServerURL = "http://localhost:4096"
    static let defaultUsername = "opencode"
    static let defaultModelID = "gpt-5.5"
    static let defaultProviderID = "openai"
    static let defaultAgent = "Sisyphus - Ultraworker"

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func sendTranscript(_ text: String, serverURL: String, username: String, password: String) async throws {
        let baseURL = try validatedBaseURL(serverURL)
        let sessionID = try await createSession(baseURL: baseURL, username: username, password: password)
        try await sendPrompt(sessionID: sessionID, text: text, baseURL: baseURL, username: username, password: password)
    }

    func testConnection(serverURL: String, username: String, password: String) async throws {
        let baseURL = try validatedBaseURL(serverURL)
        let url = baseURL.appending(path: "session")

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(authHeaderValue(username: username, password: password), forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenCodeClientError.invalidResponse
        }
        guard http.statusCode == 200 else {
            throw OpenCodeClientError.sessionCreationFailed
        }
    }

    internal func authHeaderValue(username: String, password: String) -> String {
        let credentials = "\(username):\(password)"
        return "Basic \(Data(credentials.utf8).base64EncodedString())"
    }

    private func validatedBaseURL(_ serverURL: String) throws -> URL {
        guard var components = URLComponents(string: serverURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            throw OpenCodeClientError.invalidURL
        }

        if scheme == "http", !Self.allowsInsecureHTTP(for: host) {
            throw OpenCodeClientError.insecureRemoteURL
        }
        guard scheme == "https" || scheme == "http" else {
            throw OpenCodeClientError.invalidURL
        }

        if components.path == "/" {
            components.path = ""
        }
        guard let url = components.url else {
            throw OpenCodeClientError.invalidURL
        }
        return url
    }

    static func allowsInsecureHTTP(for host: String) -> Bool {
        isLoopbackHost(host) || isTailscaleHost(host)
    }

    private static func isLoopbackHost(_ host: String) -> Bool {
        host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }

    private static func isTailscaleHost(_ host: String) -> Bool {
        host.hasSuffix(".ts.net")
    }

    private func createSession(baseURL: URL, username: String, password: String) async throws -> String {
        let url = baseURL.appending(path: "session")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(authHeaderValue(username: username, password: password), forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode([:] as [String: String])
        request.timeoutInterval = 10

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenCodeClientError.invalidResponse
        }
        guard http.statusCode == 200 else {
            throw OpenCodeClientError.sessionCreationFailed
        }
        guard let decoded = try? JSONDecoder().decode(OpenCodeSessionResponse.self, from: data), !decoded.id.isEmpty else {
            throw OpenCodeClientError.invalidResponse
        }
        return decoded.id
    }

    private func sendPrompt(sessionID: String, text: String, baseURL: URL, username: String, password: String) async throws {
        let url = baseURL.appending(path: "session").appending(path: sessionID).appending(path: "prompt_async")

        let payload = OpenCodePromptRequest(
            parts: [OpenCodePromptPart(type: "text", text: text)],
            model: OpenCodePromptModel(modelID: Self.defaultModelID, providerID: Self.defaultProviderID),
            agent: Self.defaultAgent
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(authHeaderValue(username: username, password: password), forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(payload)
        request.timeoutInterval = 60

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenCodeClientError.invalidResponse
        }
        guard http.statusCode == 204 else {
            throw OpenCodeClientError.promptSendFailed
        }
    }
}

struct MockOpenCodeClient: OpenCodeSending {
    let result: Result<Void, Error>
    let testConnectionResult: Result<Void, Error>?

    init(result: Result<Void, Error>, testConnectionResult: Result<Void, Error>? = nil) {
        self.result = result
        self.testConnectionResult = testConnectionResult
    }

    func sendTranscript(_ text: String, serverURL: String, username: String, password: String) async throws {
        try result.get()
    }

    func testConnection(serverURL: String, username: String, password: String) async throws {
        if let testConnectionResult {
            try testConnectionResult.get()
            return
        }
        try result.get()
    }
}

private struct OpenCodeSessionResponse: Decodable {
    let id: String
}

private struct OpenCodePromptRequest: Encodable {
    let parts: [OpenCodePromptPart]
    let model: OpenCodePromptModel
    let agent: String
}

private struct OpenCodePromptPart: Encodable {
    let type: String
    let text: String
}

private struct OpenCodePromptModel: Encodable {
    let modelID: String
    let providerID: String
}
