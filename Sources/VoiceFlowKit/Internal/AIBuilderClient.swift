import Foundation

public protocol AIBuilderConnectionTesting {
    func testConnection(baseURL: String, token: String) async throws
}

public enum AIBuilderClientError: Error {
    case invalidBaseURL
    case invalidResponse
    case requestFailed
}

extension AIBuilderClientError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            "The AI Builder endpoint URL is invalid."
        case .invalidResponse:
            "The server returned an unexpected response."
        case .requestFailed:
            "The connection test request failed."
        }
    }
}

public struct AIBuilderClient: AIBuilderConnectionTesting {
    public init() {}

    public func testConnection(baseURL: String, token: String) async throws {
        guard let url = URL(string: baseURL)?.appending(path: "v1/usage/summary") else {
            throw AIBuilderClientError.invalidBaseURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIBuilderClientError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw AIBuilderClientError.requestFailed
        }
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
