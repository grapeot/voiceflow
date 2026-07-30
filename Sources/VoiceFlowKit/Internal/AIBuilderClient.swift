import Foundation

public protocol AIBuilderConnectionTesting: Sendable {
    func testConnection(baseURL: String, token: String) async throws
}

public enum AIBuilderClientError: Error {
    case invalidBaseURL
    case invalidResponse
    case requestFailed(statusCode: Int)
}

extension AIBuilderClientError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            "The AI Builder endpoint URL is invalid."
        case .invalidResponse:
            "The server returned an unexpected response."
        case .requestFailed(let statusCode):
            switch statusCode {
            case 401:
                "The API token was rejected (HTTP 401). Check that the complete AI Builder token was copied."
            case 403:
                "This API token does not have access to the AI Builder API (HTTP 403)."
            case 429:
                "The AI Builder API rate limit was reached (HTTP 429). Try again shortly."
            case 500..<600:
                "The AI Builder service returned an error (HTTP \(statusCode)). Try again shortly."
            default:
                "The connection test failed (HTTP \(statusCode))."
            }
        }
    }
}

public struct AIBuilderClient: AIBuilderConnectionTesting {
    public init() {}

    public func testConnection(baseURL: String, token: String) async throws {
        let request = try Self.makeConnectionTestRequest(baseURL: baseURL, token: token)
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIBuilderClientError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw AIBuilderClientError.requestFailed(statusCode: httpResponse.statusCode)
        }
    }

    static func makeConnectionTestRequest(baseURL: String, token: String) throws -> URLRequest {
        guard let url = URL(string: baseURL)?.appending(path: "v1/audio/realtime/sessions") else {
            throw AIBuilderClientError.invalidBaseURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"vad":false}"#.utf8)
        return request
    }
}

public struct MockAIBuilderConnectionClient: AIBuilderConnectionTesting {
    public let result: Result<Void, Error>

    public init(result: Result<Void, Error>) {
        self.result = result
    }

    public func testConnection(baseURL: String, token: String) async throws {
        try result.get()
    }
}
