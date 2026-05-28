import Foundation

public protocol AIBuilderTranscribing {
    func transcribe(audioFileURL: URL, baseURL: String, token: String) async throws -> String
}

public enum AIBuilderTranscriptionError: Error {
    case invalidBaseURL
    case invalidResponse
    case requestFailed
    case emptyTranscript
}

public struct MultipartFormDataBuilder {
    public static func makeBody(
        boundary: String,
        fields: [String: String] = [:],
        fileFieldName: String,
        fileURL: URL,
        filename: String,
        mimeType: String
    ) throws -> Data {
        var body = Data()
        let lineBreak = "\r\n"

        for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
            body.appendUTF8("--\(boundary)\(lineBreak)")
            body.appendUTF8("Content-Disposition: form-data; name=\"\(name)\"\(lineBreak)\(lineBreak)")
            body.appendUTF8("\(value)\(lineBreak)")
        }

        body.appendUTF8("--\(boundary)\(lineBreak)")
        body.appendUTF8("Content-Disposition: form-data; name=\"\(fileFieldName)\"; filename=\"\(filename)\"\(lineBreak)")
        body.appendUTF8("Content-Type: \(mimeType)\(lineBreak)\(lineBreak)")
        body.append(try Data(contentsOf: fileURL))
        body.appendUTF8(lineBreak)
        body.appendUTF8("--\(boundary)--\(lineBreak)")
        return body
    }
}

public struct AIBuilderTranscriptionClient: AIBuilderTranscribing {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func transcribe(audioFileURL: URL, baseURL: String, token: String) async throws -> String {
        guard let url = URL(string: baseURL)?.appending(path: "v1/audio/transcriptions") else {
            throw AIBuilderTranscriptionError.invalidBaseURL
        }

        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let body = try MultipartFormDataBuilder.makeBody(
            boundary: boundary,
            fileFieldName: "audio_file",
            fileURL: audioFileURL,
            filename: "recording.wav",
            mimeType: "audio/wav"
        )

        let (data, response) = try await session.upload(for: request, from: body)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIBuilderTranscriptionError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw AIBuilderTranscriptionError.requestFailed
        }

        let decoded = try JSONDecoder().decode(TranscriptionResponseBody.self, from: data)
        let text = decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw AIBuilderTranscriptionError.emptyTranscript
        }
        return text
    }
}

public final class MockAIBuilderTranscriptionClient: AIBuilderTranscribing {
    public var result: Result<String, Error>

    public init(result: Result<String, Error>) {
        self.result = result
    }

    public func transcribe(audioFileURL: URL, baseURL: String, token: String) async throws -> String {
        try result.get()
    }
}

private struct TranscriptionResponseBody: Decodable {
    let text: String
}

private extension Data {
    mutating func appendUTF8(_ string: String) {
        append(Data(string.utf8))
    }
}
