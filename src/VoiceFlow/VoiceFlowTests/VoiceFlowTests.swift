//
//  VoiceFlowTests.swift
//  VoiceFlowTests
//
//  Created by Yan Wang on 5/26/26.
//

import Foundation
import Testing
@testable import VoiceFlow

@Suite(.serialized)
@MainActor
struct VoiceFlowTests {

    @Test func appStateStartsAsPureVoiceInput() async throws {
        resetOpenCodeDefaults()
        let state = AppState()

        #expect(state.recordingStatus == .idle)
        #expect(state.transcript.isEmpty)
        #expect(state.hasSavedAIBuilderToken == false)
        #expect(state.isOpenCodeConfigured == false)
        #expect(state.openCodeServerURL == "http://localhost:4096")
        #expect(state.openCodeUsername == "opencode")
        #expect(state.canCopyTranscript == false)
        #expect(state.canSendToOpenCode == false)
        #expect(state.aiBuilderEndpoint == "https://space.ai-builders.com/backend")
    }

    @Test func openCodeRequiresConfigurationAndTranscript() async throws {
        resetOpenCodeDefaults()
        let keychain = InMemoryKeychainStore()
        let state = AppState(keychainStore: keychain)

        state.transcript = "hello"
        #expect(state.canCopyTranscript == true)
        #expect(state.canSendToOpenCode == false)

        state.saveOpenCodePassword("fake-password")
        #expect(state.canSendToOpenCode == true)
    }

    @Test func openCodePasswordUsesKeychainAndClearResetsConfig() async throws {
        resetOpenCodeDefaults()
        let keychain = InMemoryKeychainStore()
        let state = AppState(keychainStore: keychain)

        state.openCodeServerURL = "https://example.test"
        state.openCodeUsername = "user"
        state.saveOpenCodePassword("  fake-password  ")

        #expect(state.hasSavedOpenCodePassword == true)
        #expect(state.isOpenCodeConfigured == true)
        #expect(state.openCodePasswordDisplayValue == "••••••••")
        #expect(try keychain.readString(for: "openCodePassword") == "fake-password")

        state.clearOpenCodeConfig()

        #expect(state.hasSavedOpenCodePassword == false)
        #expect(state.isOpenCodeConfigured == false)
        #expect(state.openCodeServerURL == "http://localhost:4096")
        #expect(state.openCodeUsername == "opencode")
        #expect(try keychain.readString(for: "openCodePassword") == nil)
    }

    @Test func openCodeClientCreatesSessionAndSendsPromptAsync() async throws {
        MockURLProtocol.requestHandler = { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic dXNlcjpwYXNz")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            if request.url?.path == "/session" {
                #expect(request.httpMethod == "POST")
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, Data("{\"id\":\"session-1\"}".utf8))
            }

            #expect(request.url?.path == "/session/session-1/prompt_async")
            #expect(request.httpMethod == "POST")
            let body = try requestBodyData(for: request)
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            let model = json?["model"] as? [String: String]
            #expect(model?["modelID"] == "gpt-5.5")
            #expect(model?["providerID"] == "openai")
            #expect(json?["agent"] as? String == "Sisyphus - Ultraworker")
            let parts = json?["parts"] as? [[String: String]]
            #expect(parts?.first?["text"] == "hello opencode")
            let response = HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = OpenCodeClient(session: URLSession(configuration: configuration))

        try await client.sendTranscript("hello opencode", serverURL: "http://localhost:4096/", username: "user", password: "pass")
    }

    @Test func openCodeClientRejectsInsecureRemoteHTTP() async throws {
        let client = OpenCodeClient(session: URLSession(configuration: .ephemeral))

        do {
            try await client.sendTranscript("hello", serverURL: "http://example.com", username: "user", password: "pass")
            #expect(Bool(false))
        } catch let error as OpenCodeClientError {
            #expect(error == .insecureRemoteURL)
        } catch {
            #expect(Bool(false))
        }
    }

    @Test func openCodeClientRejectsURLUserInfo() async throws {
        let client = OpenCodeClient(session: URLSession(configuration: .ephemeral))

        do {
            try await client.sendTranscript("hello", serverURL: "https://user@example.com", username: "user", password: "pass")
            #expect(Bool(false))
        } catch let error as OpenCodeClientError {
            #expect(error == .invalidURL)
        } catch {
            #expect(Bool(false))
        }
    }

    @Test func openCodeClientMapsSessionFailure() async throws {
        MockURLProtocol.requestHandler = { request in
            #expect(request.url?.path == "/session")
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = OpenCodeClient(session: URLSession(configuration: configuration))

        do {
            try await client.sendTranscript("hello", serverURL: "http://localhost:4096", username: "user", password: "pass")
            #expect(Bool(false))
        } catch let error as OpenCodeClientError {
            #expect(error == .sessionCreationFailed)
        } catch {
            #expect(Bool(false))
        }
    }

    @Test func openCodeSendFlowUsesSavedConfig() async throws {
        resetOpenCodeDefaults()
        let keychain = InMemoryKeychainStore()
        let state = AppState(keychainStore: keychain, openCodeClient: MockOpenCodeClient(result: .success(())))

        state.transcript = "send this"
        state.openCodeServerURL = "http://localhost:4096"
        state.openCodeUsername = "opencode"
        state.saveOpenCodePassword("fake-password")
        await state.sendTranscriptToOpenCode()

        #expect(state.openCodeSendStatus == .success)
    }

    @Test func openCodeSendFlowFailsGracefully() async throws {
        resetOpenCodeDefaults()
        let keychain = InMemoryKeychainStore()
        let state = AppState(keychainStore: keychain, openCodeClient: MockOpenCodeClient(result: .failure(OpenCodeClientError.promptSendFailed)))

        state.transcript = "send this"
        state.saveOpenCodePassword("fake-password")
        await state.sendTranscriptToOpenCode()

        if case .failed(let message) = state.openCodeSendStatus {
            #expect(message.isEmpty == false)
        } else {
            #expect(Bool(false))
        }
        #expect(state.canCopyTranscript == true)
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
        state.openCodeSendStatus = .success
        await state.startRecording()
        #expect(state.recordingStatus == .recording)
        #expect(state.openCodeSendStatus == .idle)
        await state.stopRecording()

        #expect(state.recordingStatus == .ready)
        #expect(state.transcript == "voice text")
        #expect(state.transcriptHistory.entries.map(\.text) == ["voice text"])
        #expect(clipboard.writtenText == "voice text")
    }

}

private func resetOpenCodeDefaults() {
    UserDefaults.standard.removeObject(forKey: "openCodeServerURL")
    UserDefaults.standard.removeObject(forKey: "openCodeUsername")
}

private func requestBodyData(for request: URLRequest) throws -> Data {
    if let body = request.httpBody {
        return body
    }

    guard let stream = request.httpBodyStream else {
        return Data()
    }

    stream.open()
    defer { stream.close() }

    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 1024)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count < 0 {
            throw stream.streamError ?? URLError(.cannotDecodeContentData)
        }
        if count == 0 {
            break
        }
        data.append(buffer, count: count)
    }
    return data
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
