import Foundation

/// Sends a single non-streaming chat completion to AI Builder Space and
/// parses the response into a plain transformed string. The client owns no
/// state; AppState holds ownership (request id, snapshot) and calls this
/// per attempt with a freshly-read token.
///
/// V1 sends only the common, model-agnostic request body (model, messages,
/// stream:false). No tools, no debug, no temperature — avoids known
/// per-model differences (e.g. gpt-5 forces temperature=1.0, kimi forces
/// 1.0). The fixed model is `deepseek-v4-flash`.
protocol CustomActionSending: Sendable {
    func transform(
        transcript: String,
        instructions: String,
        baseURL: String,
        token: String
    ) async throws -> String
}

enum CustomActionClientError: Error {
    case invalidBaseURL
    case invalidResponse
    case requestFailed(statusCode: Int)
    case emptyContent
    case truncated(finishReason: String)
    case nonTextContent
}

extension CustomActionClientError: LocalizedError {
    var errorDescription: String? {
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
                "The request failed (HTTP \(statusCode))."
            }
        case .emptyContent:
            "The model returned no text."
        case .truncated(let reason):
            "The model stopped early (\(reason)); the result was not used."
        case .nonTextContent:
            "The model returned non-text content."
        }
    }
}

struct CustomActionClient: CustomActionSending {
    static let requestTimeout: TimeInterval = 60

    func transform(
        transcript: String,
        instructions: String,
        baseURL: String,
        token: String
    ) async throws -> String {
        let request = try Self.makeRequest(
            transcript: transcript,
            instructions: instructions,
            baseURL: baseURL,
            token: token
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CustomActionClientError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw CustomActionClientError.requestFailed(statusCode: httpResponse.statusCode)
        }
        return try Self.parse(data: data)
    }

    static func makeRequest(
        transcript: String,
        instructions: String,
        baseURL: String,
        token: String
    ) throws -> URLRequest {
        guard let url = URL(string: baseURL)?.appending(path: "v1/chat/completions") else {
            throw CustomActionClientError.invalidBaseURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = requestTimeout

        let body: [String: Any] = [
            "model": CustomActionModel.id,
            "stream": false,
            "messages": [
                ["role": "system", "content": instructions],
                ["role": "user", "content": transcript]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Accepts a result only when it is a complete assistant text response.
    /// String content is used directly; array content concatenates text
    /// parts in order. Rejects empty choices, null, tool-only output,
    /// finish_reason != stop, and empty trimmed text. A truncated or
    /// filtered response never replaces the source transcript.
    static func parse(data: Data) throws -> String {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CustomActionClientError.invalidResponse
        }
        guard let choices = object["choices"] as? [[String: Any]], !choices.isEmpty else {
            throw CustomActionClientError.emptyContent
        }
        // Prefer index 0; tolerate servers that omit "index".
        let choice = choices.first(where: { ($0["index"] as? Int) == 0 }) ?? choices[0]

        let finishReason = (choice["finish_reason"] as? String) ?? ""
        guard finishReason == "stop" else {
            // length / tool_calls / content_filter — never replace the
            // user's text with a partial or tool-only result.
            throw CustomActionClientError.truncated(finishReason: finishReason)
        }

        guard let message = choice["message"] as? [String: Any] else {
            throw CustomActionClientError.emptyContent
        }
        // If the assistant message carries tool_calls, it is not a text
        // transform result.
        if let toolCalls = message["tool_calls"], toolCalls is [Any], !((toolCalls as? [Any])?.isEmpty ?? true) {
            throw CustomActionClientError.nonTextContent
        }

        let content = message["content"]
        let text: String
        switch content {
        case let s as String:
            text = s
        case let parts as [Any]:
            // Concatenate text parts in order; ignore non-text parts.
            text = parts.compactMap { part -> String? in
                guard let dict = part as? [String: Any] else { return nil }
                guard (dict["type"] as? String) == "text" else { return nil }
                return dict["text"] as? String
            }.joined()
        case nil:
            throw CustomActionClientError.emptyContent
        default:
            throw CustomActionClientError.nonTextContent
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CustomActionClientError.emptyContent
        }
        return trimmed
    }
}

final class MockCustomActionClient: CustomActionSending, @unchecked Sendable {
    let result: Result<String, Error>
    private(set) var lastTranscript: String?
    private(set) var lastInstructions: String?
    private(set) var lastBaseURL: String?
    private(set) var lastToken: String?
    private(set) var callCount = 0

    init(result: Result<String, Error>) {
        self.result = result
    }

    func transform(
        transcript: String,
        instructions: String,
        baseURL: String,
        token: String
    ) async throws -> String {
        callCount += 1
        lastTranscript = transcript
        lastInstructions = instructions
        lastBaseURL = baseURL
        lastToken = token
        return try result.get()
    }
}