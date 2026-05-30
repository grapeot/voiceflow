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
}

private func resetPreferenceDefaults() {
    UserDefaults.standard.removeObject(forKey: "appLanguage")
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
