//
//  VoiceFlowTests.swift
//  VoiceFlowTests
//
//  Created by Yan Wang on 5/26/26.
//

import Foundation
import Testing
@testable import VoiceFlowKit
@testable import VoiceFlow

@Suite(.serialized)
@MainActor
struct VoiceFlowTests {

    @Test func appStateStartsAsPureVoiceInput() async throws {
        resetOpenCodeDefaults()
        resetPreferenceDefaults()
        let state = AppState()

        #expect(state.recordingStatus == .idle)
        #expect(state.recordingTimerText == "00:00")
        #expect(state.transcript.isEmpty)
        #expect(state.transcriptionStrategy == .gptLiveTranscribe)
        #expect(state.hasSavedAIBuilderToken == false)
        #expect(state.isOpenCodeConfigured == false)
        #expect(state.openCodeServerURL == "http://localhost:4096")
        #expect(state.openCodeUsername == "opencode")
        #expect(state.canCopyTranscript == false)
        #expect(state.canSendToOpenCode == false)
        #expect(state.aiBuilderEndpoint == "https://space.ai-builders.com/backend")
        #expect(state.appLanguage == .system)
    }

    @Test func applyStreamedTranscriptAppendsAndReplacesWithoutChurn() async throws {
        let state = AppState()

        // Streaming hands us the whole transcript each partial. When the new
        // value extends the current one, we append only the delta (keeps the
        // TextEditor's existing prefix stable → no UITextView reset → no flash).
        state.applyStreamedTranscript("Hello")
        #expect(state.transcript == "Hello")
        state.applyStreamedTranscript("Hello world")
        #expect(state.transcript == "Hello world")
        state.applyStreamedTranscript("Hello world, how are you")
        #expect(state.transcript == "Hello world, how are you")

        // A no-op partial (same value) must not be re-assigned — even an
        // identical assignment churns the @Published binding.
        state.applyStreamedTranscript("Hello world, how are you")
        #expect(state.transcript == "Hello world, how are you")

        // A divergent value (e.g. a corrected re-transcription that is not a
        // superset) replaces wholesale.
        state.applyStreamedTranscript("Completely different text")
        #expect(state.transcript == "Completely different text")

        // Empty / shorter divergent value still replaces correctly.
        state.applyStreamedTranscript("")
        #expect(state.transcript.isEmpty)
    }

    @Test func recordingStatusIndicatorAccessibilityValues() async throws {
        #expect(AppState.RecordingStatus.idle.indicatorAccessibilityValue == "idle")
        #expect(AppState.RecordingStatus.requestingPermission.indicatorAccessibilityValue == "requestingPermission")
        #expect(AppState.RecordingStatus.recording.indicatorAccessibilityValue == "recording")
        #expect(AppState.RecordingStatus.transcribing.indicatorAccessibilityValue == "transcribing")
        #expect(AppState.RecordingStatus.ready.indicatorAccessibilityValue == "ready")
    }

    @Test func recordingTimerFormatterFormatsElapsedTime() async throws {
        #expect(RecordingTimerFormatter.format(elapsedSeconds: 0) == "00:00")
        #expect(RecordingTimerFormatter.format(elapsedSeconds: 5) == "00:05")
        #expect(RecordingTimerFormatter.format(elapsedSeconds: 65) == "01:05")
        #expect(RecordingTimerFormatter.format(elapsedSeconds: 3599) == "59:59")
    }

    @Test func languagePreferenceUsesUserDefaultsAndLocaleMapping() async throws {
        resetPreferenceDefaults()
        let state = AppState()

        state.appLanguage = .english

        #expect(AppState().appLanguage == .english)
        #expect(state.appLanguage.locale?.identifier == "en")

        state.appLanguage = .simplifiedChinese

        #expect(AppState().appLanguage == .simplifiedChinese)
        #expect(state.appLanguage.locale?.identifier == "zh-Hans")

        state.appLanguage = .system

        #expect(AppState().appLanguage == .system)
        #expect(state.appLanguage.locale == nil)
    }

    @Test func generatedStatusesStoreLocalizationKeys() async throws {
        resetPreferenceDefaults()
        let keychain = InMemoryKeychainStore()
        let state = AppState(
            keychainStore: keychain,
            aiBuilderClient: MockAIBuilderConnectionClient(result: .failure(URLError(.badServerResponse))),
            clipboardWriter: MockClipboardWriter(writeError: ClipboardTestError.writeFailed),
            openCodeClient: MockOpenCodeClient(
                result: .failure(OpenCodeClientError.promptSendFailed),
                testConnectionResult: .success(())
            )
        )

        await state.startRecording()
        #expect(state.recordingStatus == .idle)
        #expect(state.recordErrorAlertKey == "record.error.missingToken")

        state.saveAIBuilderToken("fake-token")
        await state.testAIBuilderConnection()
        if case .failed(let key, let detail) = state.connectionStatus {
            #expect(key == "settings.connection.failed")
            #expect(detail?.isEmpty == false)
        } else {
            #expect(Bool(false))
        }

        state.transcript = "private dictated words"
        state.copyTranscript()
        #expect(state.lastClipboardStatusKey == "record.clipboard.failed")

        state.saveOpenCodePassword("fake-opencode-password")
        #expect(state.canSendToOpenCode == false)
        await state.testOpenCodeConnection()
        #expect(state.openCodeConnectionStatus == .success)
        await state.sendTranscriptToOpenCode()
        #expect(state.openCodeSendStatus == .failed("record.openCode.error.sendFailed"))
    }

    @Test func openCodeRequiresConfigurationAndTranscript() async throws {
        resetOpenCodeDefaults()
        let keychain = InMemoryKeychainStore()
        let state = AppState(
            keychainStore: keychain,
            openCodeClient: MockOpenCodeClient(result: .success(()))
        )

        state.transcript = "hello"
        #expect(state.canCopyTranscript == true)
        #expect(state.canSendToOpenCode == false)

        state.saveOpenCodePassword("fake-password")
        #expect(state.canSendToOpenCode == false)

        await state.testOpenCodeConnection()
        #expect(state.canSendToOpenCode == true)
    }

    @Test func openCodeConnectionVerificationPersistsAcrossAppStateInstances() async throws {
        resetOpenCodeDefaults()
        let keychain = InMemoryKeychainStore()
        let state = AppState(
            keychainStore: keychain,
            openCodeClient: MockOpenCodeClient(result: .success(()))
        )

        state.transcript = "hello"
        state.saveOpenCodePassword("fake-password")
        await state.testOpenCodeConnection()

        let relaunched = AppState(
            keychainStore: keychain,
            openCodeClient: MockOpenCodeClient(result: .success(()))
        )
        relaunched.transcript = "hello"

        #expect(relaunched.openCodeConnectionStatus == .success)
        #expect(relaunched.canSendToOpenCode == true)

        relaunched.openCodeUsername = "other-user"
        #expect(relaunched.openCodeConnectionStatus == .untested)
        #expect(UserDefaults.standard.bool(forKey: "openCodeConnectionVerified") == false)
    }

    @Test func openCodePasswordUsesKeychainAndClearRemovesPasswordOnly() async throws {
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

        state.clearOpenCodePassword()

        #expect(state.hasSavedOpenCodePassword == false)
        #expect(state.isOpenCodeConfigured == false)
        #expect(state.openCodeServerURL == "https://example.test")
        #expect(state.openCodeUsername == "user")
        #expect(try keychain.readString(for: "openCodePassword") == nil)
    }

    @Test func connectionFailureIncludesErrorDetail() async throws {
        resetOpenCodeDefaults()
        let keychain = InMemoryKeychainStore()
        let state = AppState(
            keychainStore: keychain,
            openCodeClient: MockOpenCodeClient(
                result: .success(()),
                testConnectionResult: .failure(OpenCodeClientError.insecureRemoteURL)
            )
        )

        state.saveOpenCodePassword("fake-password")
        await state.testOpenCodeConnection()

        #expect(state.openCodeConnectionStatus == .failed(
            "settings.openCode.connection.failed",
            "Remote servers must use HTTPS. HTTP is allowed only for localhost and Tailscale (*.ts.net) hosts."
        ))
    }

    @Test func openCodeClientCreatesSessionAndSendsPromptAsync() async throws {
        MockURLProtocol.requestHandler = { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic dXNlcjpwYXNz")
            // Content-Type is asserted per-request below: only the body-carrying
            // POSTs set it. A GET (e.g. fetching messages) carries no body and so
            // no Content-Type — asserting it on *every* request made this test
            // fail whenever the GET message fetch ran (flaky across the suite).
            if request.url?.path == "/session" {
                #expect(request.httpMethod == "POST")
                #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, Data("{\"id\":\"session-1\"}".utf8))
            }

            if request.url?.path == "/session/session-1/message" {
                #expect(request.httpMethod == "GET")
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let body = "[{\"info\":{\"role\":\"user\"},\"parts\":[{\"type\":\"text\",\"text\":\"hello opencode\"}]}]"
                return (response, Data(body.utf8))
            }

            #expect(request.url?.path == "/session/session-1/prompt_async")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            let body = try requestBodyData(for: request)
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            let model = json?["model"] as? [String: String]
            #expect(model?["modelID"] == "gpt-5.5")
            #expect(model?["providerID"] == "openai")
            #expect(json?["agent"] as? String == "build")
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

    @Test func openCodeClientAllowsTailscaleHTTP() async throws {
        MockURLProtocol.requestHandler = { request in
            #expect(request.url?.host?.hasSuffix(".ts.net") == true)
            if request.url?.path == "/session", request.httpMethod == "POST" {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, Data("{\"id\":\"session-1\"}".utf8))
            }
            if request.url?.path == "/session/session-1/message" {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let body = "[{\"info\":{\"role\":\"user\"},\"parts\":[{\"type\":\"text\",\"text\":\"hello tailscale\"}]}]"
                return (response, Data(body.utf8))
            }
            #expect(request.url?.path == "/session/session-1/prompt_async")
            let response = HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = OpenCodeClient(session: URLSession(configuration: configuration))

        try await client.sendTranscript(
            "hello tailscale",
            serverURL: "http://devbox.tailabc123.ts.net:4096",
            username: "user",
            password: "pass"
        )
    }

    @Test func infoPlistAllowsInsecureHTTPForTailscaleHosts() throws {
        guard let appTransportSecurity = Bundle.main.infoDictionary?["NSAppTransportSecurity"] as? [String: Any],
              let exceptionDomains = appTransportSecurity["NSExceptionDomains"] as? [String: Any],
              let tailscaleDomain = exceptionDomains["ts.net"] as? [String: Any] else {
            Issue.record("Missing ts.net ATS exception in app Info.plist")
            return
        }

        #expect(tailscaleDomain["NSIncludesSubdomains"] as? Bool == true)
        #expect(tailscaleDomain["NSExceptionAllowsInsecureHTTPLoads"] as? Bool == true)
    }

    @Test func openCodeClientTestConnectionUsesSessionEndpoint() async throws {
        MockURLProtocol.requestHandler = { request in
            #expect(request.url?.path == "/session")
            #expect(request.httpMethod == "GET")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data("[]".utf8))
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = OpenCodeClient(session: URLSession(configuration: configuration))

        try await client.testConnection(
            serverURL: "http://localhost:4096",
            username: "user",
            password: "pass"
        )
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
        await state.testOpenCodeConnection()
        await state.sendTranscriptToOpenCode()

        #expect(state.openCodeSendStatus == .success)
    }

    @Test func openCodeSendFlowFailsGracefully() async throws {
        resetOpenCodeDefaults()
        let keychain = InMemoryKeychainStore()
        let state = AppState(keychainStore: keychain, openCodeClient: MockOpenCodeClient(
            result: .failure(OpenCodeClientError.promptSendFailed),
            testConnectionResult: .success(())
        ))

        state.transcript = "send this"
        state.saveOpenCodePassword("fake-password")
        await state.testOpenCodeConnection()
        await state.sendTranscriptToOpenCode()

        if case .failed(let key) = state.openCodeSendStatus {
            #expect(key == "record.openCode.error.sendFailed")
        } else {
            #expect(Bool(false))
        }
        #expect(state.canCopyTranscript == true)
    }

    @Test func openCodeSendRequiresVerifiedConnection() async throws {
        resetOpenCodeDefaults()
        let keychain = InMemoryKeychainStore()
        let state = AppState(
            keychainStore: keychain,
            openCodeClient: MockOpenCodeClient(result: .success(()))
        )

        state.transcript = "send this"
        state.saveOpenCodePassword("fake-password")
        #expect(state.canSendToOpenCode == false)

        await state.testOpenCodeConnection()
        #expect(state.canSendToOpenCode == true)
        await state.sendTranscriptToOpenCode()
        #expect(state.openCodeSendStatus == .success)
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

    @Test func transcriptHistoryKeepsFiveEntriesAndNavigatesBothDirections() async throws {
        var history = TranscriptHistory()

        for index in 1...6 {
            history.add("entry \(index)")
        }

        #expect(history.entries.map(\.text) == ["entry 6", "entry 5", "entry 4", "entry 3", "entry 2"])
        #expect(history.currentIndex == 0)
        #expect(history.hasPrevious == true)
        #expect(history.hasNext == false)

        #expect(history.navigatePrevious() == "entry 5")
        #expect(history.currentIndex == 1)
        #expect(history.hasNext == true)

        #expect(history.navigateNext() == "entry 6")
        #expect(history.currentIndex == 0)
        #expect(history.hasNext == false)
    }

    @Test func appStateNavigatesTranscriptHistory() async throws {
        let state = AppState(keychainStore: InMemoryKeychainStore())
        state.transcriptHistory.add("newest")
        state.transcriptHistory.add("older")
        state.transcript = "older"

        state.navigatePreviousTranscript()
        #expect(state.transcript == "newest")

        state.navigateNextTranscript()
        #expect(state.transcript == "older")
    }

    @Test func streamRecoveryDuringRecordingUsesCaptionNotAlert() async throws {
        let keychain = InMemoryKeychainStore()
        let recorder = MockAudioRecorder()
        let (client, mock) = makeStubVoiceFlowClient(liveResult: .success("voice text"))
        let state = AppState(
            keychainStore: keychain,
            audioRecorder: recorder,
            voiceFlowClient: client
        )

        state.saveAIBuilderToken("fake-token")
        await state.startRecording()
        #expect(state.recordingStatus == .recording)

        await mock.emitLiveEvent(.recoveryStarted)
        try await Task.sleep(for: .milliseconds(20))
        #expect(state.streamStatusCaptionKey == "record.status.reconnecting")
        #expect(state.recordErrorAlertKey == nil)

        await mock.emitLiveEvent(.textDelta(content: "after reconnect", isNewResponse: true))
        try await Task.sleep(for: .milliseconds(20))
        #expect(state.transcript.isEmpty)

        await mock.emitLiveEvent(.recoveryFailed(message: "network down"))
        try await Task.sleep(for: .milliseconds(20))
        #expect(state.streamStatusCaptionKey == "record.error.streamDisconnected")
        #expect(state.recordErrorAlertKey == nil)
    }

@Test func stopTranscriptionShowsSingleAlertWhenStreamAndBulkFail() async throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("voiceflow-single-alert-test.wav")
        try Data("audio-bytes".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let keychain = InMemoryKeychainStore()
        let recorder = MockAudioRecorder(outputURL: fileURL)
        let (client, _) = makeStubVoiceFlowClient(
            liveResult: .success("  "),
            bulkResult: .failure(VoiceFlowError.emptyTranscript)
        )
        let state = AppState(
            keychainStore: keychain,
            audioRecorder: recorder,
            voiceFlowClient: client
        )

        state.saveAIBuilderToken("fake-token")
        await state.startRecording()
        await state.stopRecording()

        #expect(state.recordErrorAlertKey == "record.error.transcriptionFailed")
        #expect(state.recordingStatus == .idle)
    }

    @Test func stopTranscriptionPrefersStreamResultWithoutAlert() async throws {
        let keychain = InMemoryKeychainStore()
        let recorder = MockAudioRecorder()
        let (client, _) = makeStubVoiceFlowClient(liveResult: .success("stream success text"))
        let state = AppState(
            keychainStore: keychain,
            audioRecorder: recorder,
            voiceFlowClient: client
        )

        state.saveAIBuilderToken("fake-token")
        await state.startRecording()
        await state.stopRecording()

        #expect(state.recordErrorAlertKey == nil)
        #expect(state.transcript == "stream success text")
        #expect(state.recordingStatus == .ready)
    }

    @Test func grokStrategyRecordsLocallyThenTranscribesAfterStop() async throws {
        resetTranscriptionStrategyDefault()
        defer { resetTranscriptionStrategyDefault() }
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceflow-grok-strategy-test.m4a")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let keychain = InMemoryKeychainStore()
        let recorder = MockAudioRecorder(outputURL: fileURL)
        let (client, realtimeMock) = makeStubVoiceFlowClient(
            grokResult: .success(TranscriptionResult(text: "grok result text", requestID: "grok-request"))
        )
        let state = AppState(
            keychainStore: keychain,
            audioRecorder: recorder,
            voiceFlowClient: client,
            clipboardWriter: MockClipboardWriter()
        )

        state.saveAIBuilderToken("fake-token")
        state.transcriptionStrategy = .grokBatch
        await state.startRecording()

        #expect(recorder.recordingStrategy == .grokBatch)
        #expect(state.recordingStatus == .recording)
        #expect(state.streamConnectionPhase == .disconnected)
        #expect(state.hasActiveWaveformFeedback)
        #expect(state.liveTranscriptionSession == nil)
        #expect(await realtimeMock.appendedChunkCount == 0)

        await state.stopRecording()

        #expect(state.transcript == "grok result text")
        #expect(state.lastRecordingURL?.pathExtension == "m4a")
        #expect(state.lastRecordingStrategy == .grokBatch)
        #expect(await realtimeMock.didFinalize == false)
        #expect(state.recordingStatus == .ready)
    }

    @Test func recordingStrategyIsSnapshottedAtStart() async throws {
        resetTranscriptionStrategyDefault()
        defer { resetTranscriptionStrategyDefault() }
        let keychain = InMemoryKeychainStore()
        let recorder = MockAudioRecorder()
        let state = AppState(
            keychainStore: keychain,
            audioRecorder: recorder,
            voiceFlowClient: makeStubVoiceFlowClient().0
        )

        state.saveAIBuilderToken("fake-token")
        state.transcriptionStrategy = .openAIRealtime
        await state.startRecording()
        state.transcriptionStrategy = .grokBatch

        #expect(state.activeRecordingStrategy == .openAIRealtime)
        #expect(recorder.recordingStrategy == .openAIRealtime)
    }

    @Test func gptLiveStrategyUsesRealtimeSessionPCMAndFinalize() async throws {
        resetTranscriptionStrategyDefault()
        defer { resetTranscriptionStrategyDefault() }
        let keychain = InMemoryKeychainStore()
        let recorder = MockAudioRecorder()
        let (client, realtimeMock) = makeStubVoiceFlowClient(liveResult: .success("gpt live result"))
        let state = AppState(
            keychainStore: keychain,
            audioRecorder: recorder,
            voiceFlowClient: client,
            clipboardWriter: MockClipboardWriter()
        )

        state.saveAIBuilderToken("fake-token")
        state.transcriptionStrategy = .gptLiveTranscribe
        await state.startRecording()

        #expect(state.activeRecordingStrategy == .gptLiveTranscribe)
        #expect(recorder.recordingStrategy == .gptLiveTranscribe)
        #expect(state.liveTranscriptionSession?.strategy == .gptLiveTranscribe)
        #expect(await realtimeMock.lastLiveModel == "gpt-live-transcribe")

        await state.stopRecording()

        #expect(state.transcript == "gpt live result")
        #expect(state.lastRecordingURL?.pathExtension == "wav")
        #expect(state.lastRecordingStrategy == .gptLiveTranscribe)
        #expect(await realtimeMock.didFinalize)
        #expect(state.recordingStatus == .ready)
    }

    @Test func gptLiveRecordingAndResendKeepStartStrategyAfterSettingsChange() async throws {
        resetTranscriptionStrategyDefault()
        defer { resetTranscriptionStrategyDefault() }
        let keychain = InMemoryKeychainStore()
        let recorder = MockAudioRecorder()
        let (client, realtimeMock) = makeStubVoiceFlowClient(
            liveResult: .success("first live text"),
            bulkResult: .success("resent live text")
        )
        let state = AppState(
            keychainStore: keychain,
            audioRecorder: recorder,
            voiceFlowClient: client,
            clipboardWriter: MockClipboardWriter()
        )

        state.saveAIBuilderToken("fake-token")
        state.transcriptionStrategy = .gptLiveTranscribe
        await state.startRecording()
        state.transcriptionStrategy = .grokBatch

        #expect(state.activeRecordingStrategy == .gptLiveTranscribe)
        await state.stopRecording()
        await state.resendLastRecording()

        #expect(state.transcript == "resent live text")
        #expect(state.lastRecordingStrategy == .gptLiveTranscribe)
        #expect(await realtimeMock.lastBulkStrategy == .gptLiveTranscribe)
        #expect(await realtimeMock.lastBulkModel == "gpt-live-transcribe")
    }

    @Test func microphoneChunksStayOrderedAndDrainBeforeFinalize() async throws {
        let chunks = (0..<48).map { index in
            Data(repeating: UInt8(0x10 + index % 32), count: 2_000)
        }
        let expectedPCM = chunks.reduce(into: Data()) { $0.append($1) }
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceflow-ordered-pcm-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let keychain = InMemoryKeychainStore()
        let recorder = MockAudioRecorder(
            outputURL: outputURL,
            outputPCMData: expectedPCM,
            emittedPCMChunks: chunks
        )
        let (client, realtimeMock) = makeStubVoiceFlowClient(liveResult: .success("ordered transcript"))
        let state = AppState(
            keychainStore: keychain,
            audioRecorder: recorder,
            voiceFlowClient: client,
            clipboardWriter: MockClipboardWriter()
        )

        state.saveAIBuilderToken("fake-token")
        await state.startRecording()
        #expect((state.capturedPCMBuffer?.pendingChunkCount ?? 0) <= 32)
        await state.stopRecording()

        #expect(await realtimeMock.appendedPCMData == expectedPCM)
        #expect(await realtimeMock.appendedByteCountAtFinalize == expectedPCM.count)
    }

    @Test func stopWaitsForInFlightTapCallbackBeforeWAVAndFinalize() async throws {
        let initialPCM = Data(repeating: 0x10, count: 96_000)
        let finalPCM = Data(repeating: 0x20, count: 4_000)
        let expectedPCM = initialPCM + finalPCM
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceflow-stop-callback-race-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let recorder = StopRacingAudioRecorder(
            outputURL: outputURL,
            initialPCM: initialPCM,
            finalPCM: finalPCM
        )
        let keychain = InMemoryKeychainStore()
        let (client, realtimeMock) = makeStubVoiceFlowClient(liveResult: .success("complete transcript"))
        let state = AppState(
            keychainStore: keychain,
            audioRecorder: recorder,
            voiceFlowClient: client,
            clipboardWriter: MockClipboardWriter()
        )

        state.saveAIBuilderToken("fake-token")
        await state.startRecording()
        #expect(recorder.beginFinalCallback())

        let stopTask = Task { await state.stopRecording() }
        await recorder.waitUntilStopBegan()
        #expect(!FileManager.default.fileExists(atPath: outputURL.path))

        recorder.releaseFinalCallback()
        await stopTask.value

        let persistedURL = try #require(state.lastRecordingURL)
        defer { try? FileManager.default.removeItem(at: persistedURL) }
        #expect(try PCM16WAVWriter.readPCM(from: persistedURL) == expectedPCM)
        #expect(await realtimeMock.appendedPCMData == expectedPCM)
        #expect(await realtimeMock.appendedByteCountAtFinalize == expectedPCM.count)
    }

    @Test func gptLiveFinalizeFailureRequiresExplicitResend() async throws {
        resetTranscriptionStrategyDefault()
        defer { resetTranscriptionStrategyDefault() }
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceflow-gpt-live-explicit-resend-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let keychain = InMemoryKeychainStore()
        let recorder = MockAudioRecorder(outputURL: outputURL)
        let clipboard = MockClipboardWriter()
        let (client, realtimeMock) = makeStubVoiceFlowClient(
            liveResult: .failure(VoiceFlowError.connectionLost("finalize failed")),
            bulkResult: .success("explicit resend transcript")
        )
        let state = AppState(
            keychainStore: keychain,
            audioRecorder: recorder,
            voiceFlowClient: client,
            clipboardWriter: clipboard
        )

        state.saveAIBuilderToken("fake-token")
        state.transcriptionStrategy = .gptLiveTranscribe
        await state.startRecording()
        await state.stopRecording()

        #expect(await realtimeMock.bulkCallCount == 0)
        #expect(state.recordErrorAlertKey == "record.error.transcriptionFailed")
        #expect(state.transcriptHistory.entries.isEmpty)
        #expect(clipboard.writeCount == 0)
        #expect(state.canResendRecording)

        await state.resendLastRecording()

        #expect(await realtimeMock.bulkCallCount == 1)
        #expect(state.transcript == "explicit resend transcript")
        #expect(state.transcriptHistory.entries.count == 1)
        #expect(clipboard.writeCount == 1)
    }

    @Test func originalFinalizeOwnsWritesAndGatesConcurrentResend() async throws {
        let keychain = InMemoryKeychainStore()
        let clipboard = MockClipboardWriter()
        let (client, realtimeMock) = makeStubVoiceFlowClient(
            liveResult: .success("owned finalize transcript"),
            bulkResult: .success("duplicate resend transcript")
        )
        await realtimeMock.setLiveFinalizeDelay(milliseconds: 100)
        let state = AppState(
            keychainStore: keychain,
            audioRecorder: MockAudioRecorder(),
            voiceFlowClient: client,
            clipboardWriter: clipboard
        )

        state.saveAIBuilderToken("fake-token")
        await state.startRecording()
        let stopTask = Task { await state.stopRecording() }
        while state.activeTranscriptionAttemptID == nil {
            await Task.yield()
        }

        #expect(!state.canResendRecording)
        await state.resendLastRecording()
        await stopTask.value

        #expect(await realtimeMock.bulkCallCount == 0)
        #expect(state.transcript == "owned finalize transcript")
        #expect(state.transcriptHistory.entries.count == 1)
        #expect(clipboard.writeCount == 1)
    }

    @Test func repeatedResendCreatesOnlyOneAttempt() async throws {
        let keychain = InMemoryKeychainStore()
        let clipboard = MockClipboardWriter()
        let (client, realtimeMock) = makeStubVoiceFlowClient(
            liveResult: .success("initial transcript"),
            bulkResult: .success("single resend transcript")
        )
        let state = AppState(
            keychainStore: keychain,
            audioRecorder: MockAudioRecorder(),
            voiceFlowClient: client,
            clipboardWriter: clipboard
        )

        state.saveAIBuilderToken("fake-token")
        await state.startRecording()
        await state.stopRecording()
        await realtimeMock.setBulkDelay(milliseconds: 100)

        let resendTask = Task { await state.resendLastRecording() }
        while state.activeTranscriptionAttemptID == nil {
            await Task.yield()
        }
        #expect(!state.canResendRecording)
        await state.resendLastRecording()
        await resendTask.value

        #expect(await realtimeMock.bulkCallCount == 1)
        #expect(state.transcript == "single resend transcript")
        #expect(state.transcriptHistory.entries.count == 2)
        #expect(clipboard.writeCount == 2)
    }

    @Test func latePartialCannotOverwriteCompletedAttempt() {
        let state = AppState(clipboardWriter: MockClipboardWriter())
        let attemptID = state.beginTranscriptionAttempt()!
        state.partialTranscriptAttemptID = attemptID
        state.transcript = "authoritative final"

        state.finishTranscriptionAttempt(attemptID)
        state.handleStreamEvent(.partialTranscript("late partial"))

        #expect(state.transcript == "authoritative final")
    }

    @Test func gptLiveRecordingAcceptsAccumulatedTranscriptSnapshots() {
        let state = AppState(clipboardWriter: MockClipboardWriter())
        state.activeRecordingStrategy = .gptLiveTranscribe
        state.recordingStatus = .recording

        state.handleStreamEvent(.partialTranscript("The first "))
        state.handleStreamEvent(.partialTranscript("The first sentence."))

        #expect(state.transcript == "The first sentence.")
    }

    @Test func realtimeRecordingStillSuppressesTranscriptEvents() {
        let state = AppState(clipboardWriter: MockClipboardWriter())
        state.activeRecordingStrategy = .openAIRealtime
        state.recordingStatus = .recording

        state.handleStreamEvent(.partialTranscript("should remain hidden"))

        #expect(state.transcript.isEmpty)
    }

    @Test func allRecordingStrategiesRoundTripThroughUserDefaults() {
        resetTranscriptionStrategyDefault()
        defer { resetTranscriptionStrategyDefault() }

        for strategy in VoiceFlowRecordingStrategy.allCases {
            UserDefaults.standard.set(strategy.rawValue, forKey: "transcriptionStrategy")
            #expect(AppState().transcriptionStrategy == strategy)
        }
    }

    @Test func resendUsesTheStrategyThatCreatedTheRecording() async throws {
        resetTranscriptionStrategyDefault()
        defer { resetTranscriptionStrategyDefault() }
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceflow-grok-resend-strategy-test.m4a")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let keychain = InMemoryKeychainStore()
        let recorder = MockAudioRecorder(outputURL: fileURL)
        let realtimeMock = MockRealtimeTranscriptionClient(
            bulkResult: .failure(VoiceFlowError.audioConversionFailed)
        )
        let grokMock = MockGrokBatchTranscriptionClient(
            result: .success(TranscriptionResult(text: "first grok text", requestID: "first"))
        )
        let client = VoiceFlowClient(
            config: VoiceFlowConfig(tokenProvider: { "test-token" }),
            transcriber: realtimeMock,
            grokTranscriber: grokMock
        )
        let state = AppState(
            keychainStore: keychain,
            audioRecorder: recorder,
            voiceFlowClient: client,
            clipboardWriter: MockClipboardWriter()
        )

        state.saveAIBuilderToken("fake-token")
        state.transcriptionStrategy = .grokBatch
        await state.startRecording()
        await state.stopRecording()

        grokMock.result = .success(TranscriptionResult(text: "resent grok text", requestID: "second"))
        state.transcriptionStrategy = .openAIRealtime
        await state.resendLastRecording()

        #expect(state.transcript == "resent grok text")
        #expect(grokMock.calls.count == 2)
        #expect(await realtimeMock.appendedChunkCount == 0)
    }

    @Test func streamRecoveryDuringRecordingDoesNotUpdateTranscript() async throws {
        let keychain = InMemoryKeychainStore()
        let recorder = MockAudioRecorder()
        let (client, mock) = makeStubVoiceFlowClient(liveResult: .success("voice text"))
        let state = AppState(
            keychainStore: keychain,
            audioRecorder: recorder,
            voiceFlowClient: client
        )

        state.saveAIBuilderToken("fake-token")
        await state.startRecording()

        await mock.emitLiveEvent(.textDelta(content: "before disconnect", isNewResponse: true))
        await mock.emitLiveEvent(.recoveryStarted)
        await mock.emitLiveEvent(.textDelta(content: "after reconnect", isNewResponse: true))
        try await Task.sleep(for: .milliseconds(30))

        #expect(state.transcript.isEmpty)
        #expect(state.recordErrorAlertKey == nil)

        await state.stopRecording()
        #expect(state.transcript == "voice text")
    }

    @Test func saveAndResendRecordingUsePersistedAudio() async throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("voiceflow-save-resend-test.wav")
        try Data("audio-bytes".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let keychain = InMemoryKeychainStore()
        let recorder = MockAudioRecorder(outputURL: fileURL)
        let (client, mock) = makeStubVoiceFlowClient(
            liveResult: .success("first transcript"),
            bulkResult: .success("first transcript")
        )
        let state = AppState(
            keychainStore: keychain,
            audioRecorder: recorder,
            voiceFlowClient: client,
            clipboardWriter: MockClipboardWriter()
        )

        state.saveAIBuilderToken("fake-token")
        await state.startRecording()
        await state.stopRecording()

        #expect(state.canSaveRecording == true)
        #expect(state.canResendRecording == true)

        state.saveCurrentRecording()
        #expect(state.shouldPresentSavedRecordingAlert == true)
        #expect(state.lastSavedRecording?.fileName.hasPrefix("recording_") == true)
        #expect(state.lastSavedRecording?.fileName.hasSuffix(".wav") == true)

        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let savedFiles = try FileManager.default.contentsOfDirectory(at: documentsPath, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("recording_") && $0.pathExtension == "wav" }
        defer {
            for file in savedFiles {
                try? FileManager.default.removeItem(at: file)
            }
        }
        #expect(savedFiles.isEmpty == false)
        #expect(savedFiles.contains(where: { $0.lastPathComponent == state.lastSavedRecording?.fileName }) == true)

        await mock.setBulkResult(.success("resent transcript"))
        await state.resendLastRecording()

        #expect(state.transcript == "resent transcript")
        #expect(state.transcriptHistory.entries.first?.text == "resent transcript")
    }

    @Test func resendWhileRecordingStopsLiveSessionAndUsesBulkTranscription() async throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("voiceflow-recording-resend-test.wav")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let keychain = InMemoryKeychainStore()
        let recorder = MockAudioRecorder(outputURL: fileURL, outputPCMData: Data("active-audio".utf8))
        let (client, mock) = makeStubVoiceFlowClient(
            liveResult: .success("stuck stream transcript"),
            bulkResult: .success("bulk retry transcript")
        )
        let state = AppState(
            keychainStore: keychain,
            audioRecorder: recorder,
            voiceFlowClient: client,
            clipboardWriter: MockClipboardWriter()
        )

        state.saveAIBuilderToken("fake-token")
        await state.startRecording()

        #expect(state.recordingStatus == .recording)
        #expect(state.canResendRecording == true)

        await state.resendLastRecording()

        #expect(recorder.didStop == true)
        #expect(await mock.didCancel == true)
        #expect(await mock.didFinalize == false)
        #expect(state.transcript == "bulk retry transcript")
        #expect(state.recordingStatus == .ready)
    }

    // Rescue: when transcription hangs in `.transcribing`, the user must still be
    // able to save and replay the already-recorded audio.
    @Test func saveAndResendStayEnabledWhileTranscribingIsStuck() async throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("voiceflow-stuck-transcribing-test.wav")
        try Data("audio-bytes".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let keychain = InMemoryKeychainStore()
        let recorder = MockAudioRecorder(outputURL: fileURL)
        let (client, _) = makeStubVoiceFlowClient(
            liveResult: .success("first transcript"),
            bulkResult: .success("first transcript")
        )
        let state = AppState(
            keychainStore: keychain,
            audioRecorder: recorder,
            voiceFlowClient: client,
            clipboardWriter: MockClipboardWriter()
        )

        state.saveAIBuilderToken("fake-token")
        await state.startRecording()
        await state.stopRecording()

        // Simulate the live session hanging: status stays in `.transcribing`
        // while a persisted audio file already exists on disk.
        state.recordingStatus = .transcribing
        #expect(state.lastRecordingURL != nil)

        #expect(state.canSaveRecording == true)
        #expect(state.canResendRecording == true)
    }

    // Without an audio file, save must remain disabled even in `.transcribing`.
    @Test func saveStaysDisabledWhenNoAudioFileExists() async throws {
        let keychain = InMemoryKeychainStore()
        let state = AppState(keychainStore: keychain, clipboardWriter: MockClipboardWriter())
        state.saveAIBuilderToken("fake-token")

        state.recordingStatus = .transcribing
        #expect(state.lastRecordingURL == nil)
        #expect(state.canSaveRecording == false)
    }

    @Test func recordingFileSaverCreatesTimestampedDestinationAndCopiesFile() async throws {
        let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent("voiceflow-saver-source.wav")
        let destinationDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("voiceflow-saver-dest", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        try Data("audio-bytes".utf8).write(to: sourceURL)
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: destinationDirectory)
        }

        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let destinationURL = RecordingFileSaver.makeDestinationURL(in: destinationDirectory, date: fixedDate)
        try RecordingFileSaver.saveRecording(from: sourceURL, to: destinationURL)

        #expect(destinationURL.lastPathComponent.hasPrefix("recording_"))
        #expect(destinationURL.lastPathComponent.hasSuffix(".wav"))
        #expect(FileManager.default.fileExists(atPath: destinationURL.path))
        let savedData = try Data(contentsOf: destinationURL)
        #expect(savedData == Data("audio-bytes".utf8))
    }

    @Test func recordingFileSaverThrowsWhenSourceMissing() async throws {
        let destinationURL = FileManager.default.temporaryDirectory.appendingPathComponent("voiceflow-saver-missing-dest.wav")
        defer { try? FileManager.default.removeItem(at: destinationURL) }

        let missingSourceURL = FileManager.default.temporaryDirectory.appendingPathComponent("voiceflow-saver-missing-source.wav")

        await #expect(throws: Error.self) {
            try RecordingFileSaver.saveRecording(from: missingSourceURL, to: destinationURL)
        }
    }

    @Test func saveCurrentRecordingDoesNothingWithoutPersistedAudio() async throws {
        let state = AppState(keychainStore: InMemoryKeychainStore())

        state.saveCurrentRecording()

        #expect(state.lastSavedRecording == nil)
        #expect(state.shouldPresentSavedRecordingAlert == false)
        #expect(state.lastClipboardStatusKey == nil)
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
            voiceFlowClient: makeStubVoiceFlowClient(liveResult: .success("voice text")).0,
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
        #expect(clipboard.writeCount == 1)
    }

    @Test func transcriptionPromptAndTermsPropagateIntoLiveSessionContext() async throws {
        let keychain = InMemoryKeychainStore()
        let recorder = MockAudioRecorder()
        let (client, mock) = makeStubVoiceFlowClient(liveResult: .success("voice text"))
        let state = AppState(
            keychainStore: keychain,
            audioRecorder: recorder,
            voiceFlowClient: client
        )

        state.saveAIBuilderToken("fake-token")
        state.transcriptionPrompt = "All caps please"
        state.transcriptionTerms = "Kubernetes, gRPC, , Anthropic"

        await state.startRecording()
        #expect(state.recordingStatus == .recording)

        let captured = await mock.lastLiveContext
        #expect(captured.prompt == "All caps please")
        #expect(captured.terms == ["Kubernetes", "gRPC", "Anthropic"])

        await state.stopRecording()
    }

    @Test func emptyTranscriptionPromptAndTermsResultInEmptyContext() async throws {
        let keychain = InMemoryKeychainStore()
        let recorder = MockAudioRecorder()
        let (client, mock) = makeStubVoiceFlowClient(liveResult: .success("voice text"))
        let state = AppState(
            keychainStore: keychain,
            audioRecorder: recorder,
            voiceFlowClient: client
        )

        state.saveAIBuilderToken("fake-token")
        // Default values (empty) and whitespace-only inputs should
        // translate to a nil prompt + empty terms — the host shouldn't
        // send "" to the backend.
        state.transcriptionPrompt = "   \n  "
        state.transcriptionTerms = " , , "

        await state.startRecording()
        let captured = await mock.lastLiveContext
        #expect(captured.prompt == nil)
        #expect(captured.terms.isEmpty)

        await state.stopRecording()
    }

    @Test func recordingDiagnosticsCaptureSafeSuccessPath() async throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("voiceflow-diagnostics-test.wav")
        try Data("audio".utf8).write(to: fileURL)
        let keychain = InMemoryKeychainStore()
        let recorder = MockAudioRecorder(outputURL: fileURL)
        let diagnostics = InMemoryRecordingDiagnostics()
        let state = AppState(
            keychainStore: keychain,
            audioRecorder: recorder,
            voiceFlowClient: makeStubVoiceFlowClient(liveResult: .success("private dictated words")).0,
            clipboardWriter: MockClipboardWriter(),
            diagnostics: diagnostics
        )

        state.saveAIBuilderToken("fake-sensitive-token")
        await state.startRecording()
        await state.stopRecording()

        let eventNames = diagnostics.events.map(\.name)
        #expect(eventNames.contains("recording_permission_request_started"))
        #expect(eventNames.contains("recording_start_succeeded"))
        #expect(eventNames.contains("recording_stop_succeeded"))
        #expect(eventNames.contains("transcription_finalize_started"))
        #expect(eventNames.contains("transcription_finalize_stream_done"))
        #expect(eventNames.contains("transcription_succeeded"))
        #expect(eventNames.contains("clipboard_copy_succeeded"))
        #expect(diagnostics.events.first { $0.name == "recording_stop_succeeded" }?.metadata["byteCount"] == "54")
        #expect(diagnostics.events.containsSensitiveText(["fake-sensitive-token", "private dictated words"]) == false)
    }

    @Test func recordingDiagnosticsCapturePermissionAndTranscriptionFailures() async throws {
        let keychain = InMemoryKeychainStore()
        let permissionDiagnostics = InMemoryRecordingDiagnostics()
        let deniedState = AppState(
            keychainStore: keychain,
            audioRecorder: MockAudioRecorder(permissionGranted: false),
            diagnostics: permissionDiagnostics
        )
        deniedState.saveAIBuilderToken("fake-sensitive-token")
        await deniedState.startRecording()

        #expect(permissionDiagnostics.events.map(\.name).contains("recording_permission_denied"))
        #expect(permissionDiagnostics.events.containsSensitiveText(["fake-sensitive-token"]) == false)

        let failureFileURL = FileManager.default.temporaryDirectory.appendingPathComponent("voiceflow-diagnostics-failure.wav")
        try Data("audio".utf8).write(to: failureFileURL)
        let failureDiagnostics = InMemoryRecordingDiagnostics()
        let failingState = AppState(
            keychainStore: keychain,
            audioRecorder: MockAudioRecorder(outputURL: failureFileURL),
            voiceFlowClient: makeStubVoiceFlowClient(
                liveResult: .failure(VoiceFlowError.websocketError("stream failed"))
            ).0,
            diagnostics: failureDiagnostics
        )
        failingState.saveAIBuilderToken("fake-sensitive-token")
        await failingState.startRecording()
        await failingState.stopRecording()

        #expect(failureDiagnostics.events.map(\.name).contains("transcription_response_failed"))
        #expect(failureDiagnostics.events.containsSensitiveText(["fake-sensitive-token"]) == false)
    }

    @Test func recordingDiagnosticsCaptureMissingTokenStartStopAndEmptyAudio() async throws {
        let missingTokenDiagnostics = InMemoryRecordingDiagnostics()
        let missingTokenState = AppState(
            keychainStore: InMemoryKeychainStore(),
            audioRecorder: MockAudioRecorder(),
            diagnostics: missingTokenDiagnostics
        )
        await missingTokenState.startRecording()

        #expect(missingTokenDiagnostics.events.map(\.name).contains("recording_missing_token"))

        let emptyFileURL = FileManager.default.temporaryDirectory.appendingPathComponent("voiceflow-diagnostics-empty.wav")
        FileManager.default.createFile(atPath: emptyFileURL.path, contents: Data())
        let emptyAudioDiagnostics = InMemoryRecordingDiagnostics()
        let emptyAudioState = AppState(
            keychainStore: InMemoryKeychainStore(),
            audioRecorder: MockAudioRecorder(outputURL: emptyFileURL, outputPCMData: Data()),
            diagnostics: emptyAudioDiagnostics
        )
        emptyAudioState.saveAIBuilderToken("fake-sensitive-token")
        await emptyAudioState.startRecording()
        await emptyAudioState.stopRecording()

        #expect(emptyAudioDiagnostics.events.map(\.name).contains("recording_audio_file_empty"))
        #expect(emptyAudioDiagnostics.events.first { $0.name == "recording_stop_succeeded" }?.metadata["byteCount"] == "0")
        #expect(emptyAudioDiagnostics.events.containsSensitiveText(["fake-sensitive-token"]) == false)
    }

    @Test func diagnosticErrorMetadataCapturesPhaseDomainAndCode() async throws {
        let metadata = DiagnosticErrorMetadata.metadata(
            for: AudioRecorderError.sessionSetupFailed(
                phase: .setCategory,
                underlying: NSError(domain: "com.apple.coreaudio.avfaudio", code: 561_017_449)
            )
        )

        #expect(metadata["phase"] == "setCategory")
        #expect(metadata["errorDomain"] == "com.apple.coreaudio.avfaudio")
        #expect(metadata["errorCode"] == "561017449")
    }

    @Test func recordingDiagnosticsCaptureStartStopAndClipboardFailures() async throws {
        let startDiagnostics = InMemoryRecordingDiagnostics()
        let startState = AppState(
            keychainStore: InMemoryKeychainStore(),
            audioRecorder: MockAudioRecorder(startError: AudioRecorderError.recordingDidNotStart),
            diagnostics: startDiagnostics
        )
        startState.saveAIBuilderToken("fake-sensitive-token")
        await startState.startRecording()

        #expect(startDiagnostics.events.map(\.name).contains("recording_start_failed"))
        let startFailureEvent = startDiagnostics.events.first { $0.name == "recording_start_failed" }
        #expect(startFailureEvent?.metadata["phase"] == "beginRecording")

        let detailedDiagnostics = InMemoryRecordingDiagnostics()
        let detailedState = AppState(
            keychainStore: InMemoryKeychainStore(),
            audioRecorder: MockAudioRecorder(startError: AudioRecorderError.sessionSetupFailed(
                phase: .setActive,
                underlying: NSError(domain: NSOSStatusErrorDomain, code: 560_557_684)
            )),
            diagnostics: detailedDiagnostics
        )
        detailedState.saveAIBuilderToken("fake-sensitive-token")
        await detailedState.startRecording()

        let detailedFailureEvent = detailedDiagnostics.events.first { $0.name == "recording_start_failed" }
        #expect(detailedFailureEvent?.metadata["phase"] == "setActive")
        #expect(detailedFailureEvent?.metadata["errorDomain"] == NSOSStatusErrorDomain)
        #expect(detailedFailureEvent?.metadata["errorCode"] == "560557684")

        let stopDiagnostics = InMemoryRecordingDiagnostics()
        let stopState = AppState(
            keychainStore: InMemoryKeychainStore(),
            audioRecorder: MockAudioRecorder(stopError: AudioRecorderError.noActiveRecording),
            diagnostics: stopDiagnostics
        )
        stopState.saveAIBuilderToken("fake-sensitive-token")
        await stopState.startRecording()
        await stopState.stopRecording()

        #expect(stopDiagnostics.events.map(\.name).contains("recording_stop_failed"))

        let skippedClipboardDiagnostics = InMemoryRecordingDiagnostics()
        let skippedClipboardState = AppState(
            keychainStore: InMemoryKeychainStore(),
            diagnostics: skippedClipboardDiagnostics
        )
        skippedClipboardState.copyTranscript()

        #expect(skippedClipboardDiagnostics.events.map(\.name).contains("clipboard_copy_skipped"))

        let failedClipboardDiagnostics = InMemoryRecordingDiagnostics()
        let failedClipboardState = AppState(
            keychainStore: InMemoryKeychainStore(),
            clipboardWriter: MockClipboardWriter(writeError: ClipboardTestError.writeFailed),
            diagnostics: failedClipboardDiagnostics
        )
        failedClipboardState.transcript = "private dictated words"
        failedClipboardState.copyTranscript()

        #expect(failedClipboardDiagnostics.events.map(\.name).contains("clipboard_copy_failed"))
        #expect(failedClipboardDiagnostics.events.containsSensitiveText(["private dictated words"]) == false)
    }

    @Test func recordingDiagnosticsCaptureTranscriptionResponseAndOpenCodeEvents() async throws {
        let responseFileURL = FileManager.default.temporaryDirectory.appendingPathComponent("voiceflow-diagnostics-response.wav")
        try Data("audio".utf8).write(to: responseFileURL)
        let responseDiagnostics = InMemoryRecordingDiagnostics()
        let responseState = AppState(
            keychainStore: InMemoryKeychainStore(),
            audioRecorder: MockAudioRecorder(outputURL: responseFileURL),
            voiceFlowClient: makeStubVoiceFlowClient(
                liveResult: .failure(VoiceFlowError.emptyTranscript)
            ).0,
            diagnostics: responseDiagnostics
        )
        responseState.saveAIBuilderToken("fake-sensitive-token")
        await responseState.startRecording()
        await responseState.stopRecording()

        #expect(responseDiagnostics.events.map(\.name).contains("transcription_response_failed"))

        let openCodeSuccessDiagnostics = InMemoryRecordingDiagnostics()
        let openCodeSuccessState = AppState(
            keychainStore: InMemoryKeychainStore(),
            openCodeClient: MockOpenCodeClient(result: .success(())),
            diagnostics: openCodeSuccessDiagnostics
        )
        openCodeSuccessState.transcript = "private dictated words"
        openCodeSuccessState.saveOpenCodePassword("fake-opencode-password")
        await openCodeSuccessState.testOpenCodeConnection()
        await openCodeSuccessState.sendTranscriptToOpenCode()

        let successEventNames = openCodeSuccessDiagnostics.events.map(\.name)
        #expect(successEventNames.contains("opencode_send_started"))
        #expect(successEventNames.contains("opencode_send_succeeded"))
        #expect(openCodeSuccessDiagnostics.events.containsSensitiveText(["fake-opencode-password", "private dictated words"]) == false)

        let openCodeFailureDiagnostics = InMemoryRecordingDiagnostics()
        let openCodeFailureState = AppState(
            keychainStore: InMemoryKeychainStore(),
            openCodeClient: MockOpenCodeClient(
                result: .failure(OpenCodeClientError.promptSendFailed),
                testConnectionResult: .success(())
            ),
            diagnostics: openCodeFailureDiagnostics
        )
        openCodeFailureState.transcript = "private dictated words"
        openCodeFailureState.saveOpenCodePassword("fake-opencode-password")
        await openCodeFailureState.testOpenCodeConnection()
        await openCodeFailureState.sendTranscriptToOpenCode()

        #expect(openCodeFailureDiagnostics.events.map(\.name).contains("opencode_send_failed"))
        #expect(openCodeFailureDiagnostics.events.containsSensitiveText(["fake-opencode-password", "private dictated words"]) == false)
    }

    @Test func deepLinkParserAcceptsRecordURLVariants() async throws {
        #expect(DeepLink.parse(URL(string: "voiceflow://record")!) == .startRecording)
        #expect(DeepLink.parse(URL(string: "voiceflow://record/")!) == .startRecording)
        #expect(DeepLink.parse(URL(string: "voiceflow:///record")!) == .startRecording)
        #expect(DeepLink.parse(URL(string: "voiceflow://settings")!) == nil)
        #expect(DeepLink.parse(URL(string: "https://example.test/record")!) == nil)
    }

    @Test func deepLinkRecordURLStartsRecordingAndSwitchesToRecordTab() async throws {
        let keychain = InMemoryKeychainStore()
        let recorder = MockAudioRecorder()
        let state = AppState(
            keychainStore: keychain,
            audioRecorder: recorder
        )

        state.selectedTab = .settings
        state.handleIncomingURL(URL(string: "voiceflow://record?token=ignored")!)

        #expect(state.selectedTab == .record)
        #expect(state.pendingDeepLinkStartRecording == true)

        state.saveAIBuilderToken("fake-token")
        await state.consumePendingDeepLinkStartRecordingIfNeeded()

        #expect(state.pendingDeepLinkStartRecording == false)
        #expect(state.recordingStatus == .recording)
    }

    @Test func startRecordingIntentRequestStartsRecordingAndSwitchesToRecordTab() async throws {
        StartRecordingIntentRequest.clearPendingForTests()
        let keychain = InMemoryKeychainStore()
        let recorder = MockAudioRecorder()

        StartRecordingIntentRequest.markPending()
        let state = AppState(
            keychainStore: keychain,
            audioRecorder: recorder
        )

        #expect(state.selectedTab == .record)
        #expect(state.pendingDeepLinkStartRecording == true)
        #expect(StartRecordingIntentRequest.consumePending() == false)

        state.saveAIBuilderToken("fake-token")
        await state.consumePendingDeepLinkStartRecordingIfNeeded()

        #expect(state.pendingDeepLinkStartRecording == false)
        #expect(state.recordingStatus == .recording)
        StartRecordingIntentRequest.clearPendingForTests()
    }

    @Test func deepLinkIgnoresUnknownURLsAndDoesNotLogQueryValues() async throws {
        let diagnostics = InMemoryRecordingDiagnostics()
        let state = AppState(
            keychainStore: InMemoryKeychainStore(),
            diagnostics: diagnostics
        )

        state.handleIncomingURL(URL(string: "voiceflow://settings?secret=abc")!)

        #expect(state.pendingDeepLinkStartRecording == false)
        #expect(diagnostics.events.map(\.name).contains("deeplink_ignored"))
        #expect(diagnostics.events.containsSensitiveText(["abc"]) == false)
    }


}

private func resetOpenCodeDefaults() {
    UserDefaults.standard.removeObject(forKey: "openCodeServerURL")
    UserDefaults.standard.removeObject(forKey: "openCodeUsername")
    UserDefaults.standard.removeObject(forKey: "openCodeConnectionVerified")
}

private func resetPreferenceDefaults() {
    UserDefaults.standard.removeObject(forKey: "appLanguage")
    resetTranscriptionStrategyDefault()
    StartRecordingIntentRequest.clearPendingForTests()
}

private func resetTranscriptionStrategyDefault() {
    UserDefaults.standard.removeObject(forKey: "transcriptionStrategy")
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


private extension Array where Element == RecordingDiagnosticEvent {
    func containsSensitiveText(_ sensitiveTexts: [String]) -> Bool {
        let haystack = flatMap { event in
            [event.name] + event.metadata.flatMap { [$0.key, $0.value] }
        }.joined(separator: " ")
        return sensitiveTexts.contains { haystack.contains($0) }
    }
}

private enum ClipboardTestError: Error {
    case writeFailed
}

private final class StopRacingAudioRecorder: AudioRecording, @unchecked Sendable {
    private let lock = NSLock()
    private let callbackDelivery = AudioTapCallbackDeliveryCoordinator()
    private let outputURL: URL
    private let initialPCM: Data
    private let finalPCM: Data
    private var pcmData = Data()
    private var chunkHandler: (@Sendable (Data) -> Void)?
    private var finalCallbackLease: AudioTapCallbackDeliveryCoordinator.Lease?
    private var stopBegan = false
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []

    init(outputURL: URL, initialPCM: Data, finalPCM: Data) {
        self.outputURL = outputURL
        self.initialPCM = initialPCM
        self.finalPCM = finalPCM
    }

    func requestPermission() async -> Bool {
        true
    }

    func startRecording(onPCMChunk: (@Sendable (Data) -> Void)?) async throws {
        try await startRecording(strategy: .openAIRealtime, onPCMChunk: onPCMChunk)
    }

    func startRecording(
        strategy: VoiceFlowRecordingStrategy,
        onPCMChunk: (@Sendable (Data) -> Void)?
    ) async throws {
        lock.lock()
        chunkHandler = onPCMChunk
        lock.unlock()
        deliver(initialPCM)
    }

    func beginFinalCallback() -> Bool {
        guard let lease = callbackDelivery.beginCallback() else { return false }
        lock.lock()
        finalCallbackLease = lease
        lock.unlock()
        return true
    }

    func releaseFinalCallback() {
        lock.lock()
        let lease = finalCallbackLease
        finalCallbackLease = nil
        lock.unlock()
        lease?.deliver(finalPCM) { [weak self] data in
            self?.deliver(data)
        }
    }

    func stopRecording() async throws -> URL {
        let waiters: [CheckedContinuation<Void, Never>]
        lock.lock()
        stopBegan = true
        waiters = stopWaiters
        stopWaiters.removeAll()
        lock.unlock()
        waiters.forEach { $0.resume() }

        await callbackDelivery.finish()
        lock.lock()
        let snapshot = pcmData
        lock.unlock()
        try PCM16WAVWriter.write(pcmData: snapshot, to: outputURL)
        return outputURL
    }

    func waitUntilStopBegan() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if stopBegan {
                lock.unlock()
                continuation.resume()
            } else {
                stopWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func discardRecording() {
        callbackDelivery.finishBlocking()
        try? FileManager.default.removeItem(at: outputURL)
    }

    private func deliver(_ data: Data) {
        let handler: (@Sendable (Data) -> Void)?
        lock.lock()
        pcmData.append(data)
        handler = chunkHandler
        lock.unlock()
        handler?(data)
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
