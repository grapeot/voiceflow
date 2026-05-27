//
//  VoiceFlowTests.swift
//  VoiceFlowTests
//
//  Created by Yan Wang on 5/26/26.
//

import Foundation
import Testing
@testable import VoiceFlow

@MainActor
struct VoiceFlowTests {

    @Test func appStateStartsAsPureVoiceInput() async throws {
        let state = AppState()

        #expect(state.recordingStatus == .idle)
        #expect(state.transcript.isEmpty)
        #expect(state.hasSavedAIBuilderToken == false)
        #expect(state.isOpenCodeConfigured == false)
        #expect(state.canCopyTranscript == false)
        #expect(state.canSendToOpenCode == false)
        #expect(state.aiBuilderEndpoint == "https://space.ai-builders.com/backend")
    }

    @Test func openCodeRequiresConfigurationAndTranscript() async throws {
        let state = AppState()

        state.transcript = "hello"
        #expect(state.canCopyTranscript == true)
        #expect(state.canSendToOpenCode == false)

        state.isOpenCodeConfigured = true
        #expect(state.canSendToOpenCode == true)
    }

    @Test func tokenSaveClearAndMaskingUseKeychain() async throws {
        let keychain = InMemoryKeychainStore()
        let state = AppState(keychainStore: keychain, aiBuilderClient: MockAIBuilderConnectionClient(result: .success(())))

        state.saveAIBuilderToken("  fake-token  ")

        #expect(state.hasSavedAIBuilderToken == true)
        #expect(state.tokenDisplayValue == "••••••••")
        #expect(try keychain.readString(for: "aiBuilderToken") == "fake-token")

        state.clearAIBuilderToken()

        #expect(state.hasSavedAIBuilderToken == false)
        #expect(state.tokenDisplayValue == "")
        #expect(try keychain.readString(for: "aiBuilderToken") == nil)
    }

    @Test func connectionTestUsesSavedToken() async throws {
        let keychain = InMemoryKeychainStore()
        let state = AppState(keychainStore: keychain, aiBuilderClient: MockAIBuilderConnectionClient(result: .success(())))

        state.saveAIBuilderToken("fake-token")
        await state.testAIBuilderConnection()

        #expect(state.connectionStatus == .success)
    }

    @Test func transcriptHistoryKeepsFiveEntriesAndRestoresPrevious() async throws {
        var history = TranscriptHistory()

        for index in 1...6 {
            history.add("entry \(index)")
        }

        #expect(history.entries.map(\.text) == ["entry 6", "entry 5", "entry 4", "entry 3", "entry 2"])
        #expect(history.restorePrevious(currentText: "entry 6") == "entry 5")
        #expect(history.restorePrevious(currentText: "unknown") == "entry 6")
    }

    @Test func multipartBodyUsesAudioFileFieldAndClosingBoundary() async throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("voiceflow-test.wav")
        try Data("audio".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let body = try MultipartFormDataBuilder.makeBody(
            boundary: "boundary-test",
            fields: ["language": "en"],
            fileFieldName: "audio_file",
            fileURL: fileURL,
            filename: "recording.wav",
            mimeType: "audio/wav"
        )
        let text = String(decoding: body, as: UTF8.self)

        #expect(text.contains("Content-Disposition: form-data; name=\"language\""))
        #expect(text.contains("Content-Disposition: form-data; name=\"audio_file\"; filename=\"recording.wav\""))
        #expect(text.contains("Content-Type: audio/wav"))
        #expect(text.hasSuffix("--boundary-test--\r\n"))
    }

    @Test func transcriptionClientBuildsAuthorizedUploadRequest() async throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("voiceflow-upload-test.wav")
        try Data("audio".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        MockURLProtocol.requestHandler = { request in
            #expect(request.url?.absoluteString == "https://space.ai-builders.com/backend/v1/audio/transcriptions")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fake-token")
            #expect(request.value(forHTTPHeaderField: "Content-Type")?.contains("multipart/form-data; boundary=") == true)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data("{\"text\":\"hello world\"}".utf8))
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = AIBuilderTranscriptionClient(session: URLSession(configuration: configuration))

        let text = try await client.transcribe(audioFileURL: fileURL, baseURL: "https://space.ai-builders.com/backend", token: "fake-token")

        #expect(text == "hello world")
    }

    @Test func recordingFlowUsesMocksAndCopiesTranscript() async throws {
        let keychain = InMemoryKeychainStore()
        let recorder = MockAudioRecorder()
        let clipboard = MockClipboardWriter()
        let state = AppState(
            keychainStore: keychain,
            aiBuilderClient: MockAIBuilderConnectionClient(result: .success(())),
            audioRecorder: recorder,
            transcriptionClient: MockAIBuilderTranscriptionClient(result: .success("voice text")),
            clipboardWriter: clipboard
        )

        state.saveAIBuilderToken("fake-token")
        await state.startRecording()
        #expect(state.recordingStatus == .recording)
        await state.stopRecording()

        #expect(state.recordingStatus == .ready)
        #expect(state.transcript == "voice text")
        #expect(state.transcriptHistory.entries.map(\.text) == ["voice text"])
        #expect(clipboard.writtenText == "voice text")
    }

}

final class MockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let requestHandler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try requestHandler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
