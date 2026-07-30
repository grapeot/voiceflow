import Foundation
import Testing
@testable import VoiceFlowKit

@Suite("Grok batch transcription", .serialized)
struct GrokBatchTranscriptionTests {
    @Test func multipartRequestPreservesMountFilenameAndTerms() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceflow-grok-test.m4a")
        try Data("audio".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let recorder = RequestRecorder()
        MockURLProtocol.recorder = recorder
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = GrokBatchTranscriptionClient(session: URLSession(configuration: configuration))

        let result = try await client.transcribe(
            audioFileURL: fileURL,
            baseURL: "https://example.test/backend",
            token: "builder-token",
            terms: [" Grok ", "", "xAI"]
        )

        #expect(result == TranscriptionResult(text: "hello", requestID: "server-id"))
        let captured = try #require(recorder.request)
        #expect(captured.url?.absoluteString == "https://example.test/backend/v1/audio/grok-transcription")
        #expect(captured.value(forHTTPHeaderField: "Authorization") == "Bearer builder-token")
        let body = String(decoding: recorder.body, as: UTF8.self)
        #expect(body.contains("name=\"audio_file\"; filename=\"voiceflow-grok-test.m4a\""))
        #expect(body.contains("Content-Type: audio/mp4"))
        #expect(body.contains("name=\"terms\""))
        #expect(body.contains("Grok,xAI"))
        #expect(!body.contains("name=\"prompt\""))
        #expect(!body.contains("name=\"simple\""))
    }

    @Test func strategyRoutesToGrokWithoutRealtimeBulk() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceflow-route-test.m4a")
        try Data("audio".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let realtime = MockRealtimeTranscriptionClient()
        let grok = MockGrokBatchTranscriptionClient(
            result: .success(TranscriptionResult(text: "batch", requestID: "grok-id"))
        )
        let client = VoiceFlowClient(
            config: VoiceFlowConfig(tokenProvider: { "token" }, terms: ["term"]),
            transcriber: realtime,
            grokTranscriber: grok
        )

        let result = try await client.transcribe(audioFile: fileURL, strategy: .grokBatch)

        #expect(result.text == "batch")
        #expect(grok.calls.count == 1)
        #expect(grok.calls.first?.1 == ["term"])
        #expect(await realtime.lastBulkContext == .empty)
    }
}

private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequest: URLRequest?
    private var storedBody = Data()

    var request: URLRequest? {
        lock.withLock { storedRequest }
    }

    var body: Data {
        lock.withLock { storedBody }
    }

    func record(request: URLRequest, body: Data) {
        lock.withLock {
            storedRequest = request
            storedBody = body
        }
    }
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var recorder = RequestRecorder()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? Self.readBodyStream(request.httpBodyStream)
        Self.recorder.record(request: request, body: body)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"request_id":"server-id","text":"hello"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readBodyStream(_ stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            result.append(buffer, count: count)
        }
        return result
    }
}
