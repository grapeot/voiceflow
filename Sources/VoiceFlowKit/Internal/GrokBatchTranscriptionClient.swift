import Foundation

protocol GrokBatchTranscribing: Sendable {
    func transcribe(
        audioFileURL: URL,
        baseURL: String,
        token: String,
        terms: [String]
    ) async throws -> TranscriptionResult
}

struct GrokBatchTranscriptionClient: GrokBatchTranscribing {
    static let maximumUploadBytes = 32 * 1024 * 1024

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func transcribe(
        audioFileURL: URL,
        baseURL: String,
        token: String,
        terms: [String]
    ) async throws -> TranscriptionResult {
        let attributes = try FileManager.default.attributesOfItem(atPath: audioFileURL.path)
        let byteCount = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard byteCount > 0, byteCount <= Self.maximumUploadBytes else {
            throw VoiceFlowError.audioConversionFailed
        }

        let base: URL
        do {
            base = try RealtimeAPIURLBuilder.normalizedBaseURL(from: baseURL)
        } catch {
            throw VoiceFlowError.invalidEndpoint
        }
        guard let url = RealtimeAPIURLBuilder.buildAPIURL(
            base: base,
            path: "/v1/audio/grok-transcription"
        ) else {
            throw VoiceFlowError.invalidEndpoint
        }

        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let cleanTerms = terms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let fields = cleanTerms.isEmpty ? [:] : ["terms": cleanTerms.joined(separator: ",")]
        let body = try MultipartFormDataBuilder.makeBody(
            boundary: boundary,
            fields: fields,
            fileFieldName: "audio_file",
            fileURL: audioFileURL,
            filename: audioFileURL.lastPathComponent,
            mimeType: Self.mimeType(for: audioFileURL.pathExtension)
        )

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.upload(for: request, from: body)
        } catch {
            throw VoiceFlowError.underlying(String(describing: error))
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw VoiceFlowError.underlying("Invalid HTTP response")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw VoiceFlowError.httpError(statusCode: httpResponse.statusCode)
        }

        let decoded: GrokResponse
        do {
            decoded = try JSONDecoder().decode(GrokResponse.self, from: data)
        } catch {
            throw VoiceFlowError.underlying("Invalid Grok transcription response")
        }
        let text = decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw VoiceFlowError.emptyTranscript }
        return TranscriptionResult(text: text, requestID: decoded.requestID)
    }

    private static func mimeType(for rawExtension: String) -> String {
        switch rawExtension.lowercased() {
        case "m4a", "mp4": "audio/mp4"
        case "wav": "audio/wav"
        case "mp3": "audio/mpeg"
        case "aac": "audio/aac"
        case "ogg", "opus": "audio/ogg"
        case "flac": "audio/flac"
        default: "application/octet-stream"
        }
    }
}

private struct GrokResponse: Decodable {
    let requestID: String
    let text: String

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case text
    }
}

final class MockGrokBatchTranscriptionClient: GrokBatchTranscribing, @unchecked Sendable {
    var result: Result<TranscriptionResult, Error>
    private(set) var calls: [(URL, [String])] = []

    init(result: Result<TranscriptionResult, Error>) {
        self.result = result
    }

    func transcribe(
        audioFileURL: URL,
        baseURL: String,
        token: String,
        terms: [String]
    ) async throws -> TranscriptionResult {
        calls.append((audioFileURL, terms))
        return try result.get()
    }
}
