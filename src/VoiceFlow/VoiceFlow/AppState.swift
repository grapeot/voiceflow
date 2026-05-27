import Combine
import Foundation

@MainActor
final class AppState: ObservableObject {
    enum RecordingStatus: Equatable {
        case idle
        case requestingPermission
        case recording
        case transcribing
        case ready
        case error(String)

        var localizedText: String {
            switch self {
            case .idle:
                String(localized: "record.status.idle")
            case .requestingPermission:
                String(localized: "record.status.requestingPermission")
            case .recording:
                String(localized: "record.status.recording")
            case .transcribing:
                String(localized: "record.status.transcribing")
            case .ready:
                String(localized: "record.status.ready")
            case .error(let message):
                message
            }
        }
    }

    @Published var recordingStatus: RecordingStatus = .idle
    @Published var transcript: String = ""
    @Published var transcriptHistory = TranscriptHistory()
    @Published var hasSavedAIBuilderToken = false
    @Published var openCodeServerURL: String {
        didSet { UserDefaults.standard.set(openCodeServerURL, forKey: Self.openCodeServerURLDefaultsKey) }
    }
    @Published var openCodeUsername: String {
        didSet { UserDefaults.standard.set(openCodeUsername, forKey: Self.openCodeUsernameDefaultsKey) }
    }
    @Published var hasSavedOpenCodePassword = false
    @Published var openCodeSendStatus: OpenCodeSendStatus = .idle
    @Published var lastClipboardStatus: String?
    @Published var connectionStatus: ConnectionStatus = .untested

    let aiBuilderEndpoint = "https://space.ai-builders.com/backend"
    private let keychainStore: KeychainStoring
    private let aiBuilderClient: AIBuilderConnectionTesting
    private let audioRecorder: AudioRecording
    private let transcriptionClient: AIBuilderTranscribing
    private let clipboardWriter: ClipboardWriting
    private let openCodeClient: OpenCodeSending
    private let diagnostics: RecordingDiagnosticsReporting
    private let tokenKey = "aiBuilderToken"
    private let openCodePasswordKey = "openCodePassword"
    private static let openCodeServerURLDefaultsKey = "openCodeServerURL"
    private static let openCodeUsernameDefaultsKey = "openCodeUsername"

    init(
        keychainStore: KeychainStoring? = nil,
        aiBuilderClient: AIBuilderConnectionTesting? = nil,
        audioRecorder: AudioRecording? = nil,
        transcriptionClient: AIBuilderTranscribing? = nil,
        clipboardWriter: ClipboardWriting? = nil,
        openCodeClient: OpenCodeSending? = nil,
        diagnostics: RecordingDiagnosticsReporting? = nil
    ) {
        let isUITestMode = ProcessInfo.processInfo.arguments.contains("-uiTestMode")
        self.openCodeServerURL = UserDefaults.standard.string(forKey: Self.openCodeServerURLDefaultsKey) ?? OpenCodeClient.defaultServerURL
        self.openCodeUsername = UserDefaults.standard.string(forKey: Self.openCodeUsernameDefaultsKey) ?? OpenCodeClient.defaultUsername
        self.keychainStore = keychainStore ?? (isUITestMode ? InMemoryKeychainStore() : KeychainStore())
        if let aiBuilderClient {
            self.aiBuilderClient = aiBuilderClient
        } else if isUITestMode {
            self.aiBuilderClient = MockAIBuilderConnectionClient(result: .success(()))
        } else {
            self.aiBuilderClient = AIBuilderClient()
        }
        self.audioRecorder = audioRecorder ?? (isUITestMode ? MockAudioRecorder() : AudioRecorder())
        self.transcriptionClient = transcriptionClient ?? (isUITestMode ? MockAIBuilderTranscriptionClient(result: .success("Mock transcription")) : AIBuilderTranscriptionClient())
        self.clipboardWriter = clipboardWriter ?? (isUITestMode ? MockClipboardWriter() : SystemClipboardWriter())
        self.openCodeClient = openCodeClient ?? (isUITestMode ? MockOpenCodeClient(result: .success(())) : OpenCodeClient())
        self.diagnostics = diagnostics ?? (isUITestMode ? InMemoryRecordingDiagnostics() : OSRecordingDiagnostics())
        if isUITestMode, ProcessInfo.processInfo.arguments.contains("-uiTestSavedToken") {
            try? self.keychainStore.saveString("fake-ui-token", for: tokenKey)
        }
        if isUITestMode, ProcessInfo.processInfo.arguments.contains("-uiTestSavedOpenCode") {
            self.openCodeServerURL = OpenCodeClient.defaultServerURL
            self.openCodeUsername = OpenCodeClient.defaultUsername
            try? self.keychainStore.saveString("fake-opencode-password", for: openCodePasswordKey)
        }
        self.hasSavedAIBuilderToken = (try? self.keychainStore.readString(for: tokenKey)) != nil
        self.hasSavedOpenCodePassword = (try? self.keychainStore.readString(for: openCodePasswordKey)) != nil
    }

    var canCopyTranscript: Bool {
        !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canSendToOpenCode: Bool {
        canCopyTranscript && isOpenCodeConfigured
    }

    var isOpenCodeConfigured: Bool {
        hasSavedOpenCodePassword
            && !openCodeServerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !openCodeUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var openCodePasswordDisplayValue: String {
        hasSavedOpenCodePassword ? "••••••••" : ""
    }

    var canStartRecording: Bool {
        recordingStatus == .idle || recordingStatus == .ready
    }

    var canStopRecording: Bool {
        recordingStatus == .recording
    }

    var canRestorePreviousTranscript: Bool {
        transcriptHistory.canRestorePrevious
    }

    var tokenDisplayValue: String {
        hasSavedAIBuilderToken ? "••••••••" : ""
    }

    func saveAIBuilderToken(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try keychainStore.saveString(trimmed, for: tokenKey)
            hasSavedAIBuilderToken = true
            connectionStatus = .untested
        } catch {
            connectionStatus = .failed(String(localized: "settings.connection.saveFailed"))
        }
    }

    func clearAIBuilderToken() {
        do {
            try keychainStore.deleteString(for: tokenKey)
        } catch {
            connectionStatus = .failed(String(localized: "settings.connection.clearFailed"))
            return
        }
        hasSavedAIBuilderToken = false
        connectionStatus = .untested
    }

    func testAIBuilderConnection() async {
        guard let token = try? keychainStore.readString(for: tokenKey), !token.isEmpty else {
            connectionStatus = .failed(String(localized: "settings.connection.missingToken"))
            return
        }

        connectionStatus = .testing
        do {
            try await aiBuilderClient.testConnection(baseURL: aiBuilderEndpoint, token: token)
            connectionStatus = .success
        } catch {
            connectionStatus = .failed(String(localized: "settings.connection.failed"))
        }
    }

    func startRecording() async {
        guard hasSavedAIBuilderToken else {
            recordDiagnostic("recording_missing_token", metadata: ["hasToken": "false"])
            recordingStatus = .error(String(localized: "record.error.missingToken"))
            return
        }

        recordingStatus = .requestingPermission
        recordDiagnostic("recording_permission_request_started")
        guard await audioRecorder.requestPermission() else {
            recordDiagnostic("recording_permission_denied")
            recordingStatus = .error(String(localized: "record.error.microphoneDenied"))
            return
        }

        do {
            transcript = ""
            lastClipboardStatus = nil
            openCodeSendStatus = .idle
            recordDiagnostic("recording_start_requested", metadata: ["hasToken": "true"])
            try await audioRecorder.startRecording()
            recordDiagnostic("recording_start_succeeded")
            recordingStatus = .recording
        } catch {
            recordDiagnostic("recording_start_failed", metadata: diagnosticMetadata(for: error))
            recordingStatus = .error(String(localized: "record.error.recordingFailed"))
        }
    }

    func stopRecording() async {
        guard recordingStatus == .recording else { return }
        recordingStatus = .transcribing
        recordDiagnostic("recording_stop_requested")

        let audioURL: URL
        do {
            audioURL = try await audioRecorder.stopRecording()
        } catch {
            recordDiagnostic("recording_stop_failed", metadata: diagnosticMetadata(for: error))
            recordingStatus = .error(String(localized: "record.error.transcriptionFailed"))
            return
        }

        defer { try? FileManager.default.removeItem(at: audioURL) }
        let audioMetadata = audioFileMetadata(for: audioURL)
        recordDiagnostic("recording_stop_succeeded", metadata: audioMetadata)
        if audioMetadata["byteCount"] == "0" {
            recordDiagnostic("recording_audio_file_empty")
            recordingStatus = .error(String(localized: "record.error.transcriptionFailed"))
            return
        }

        guard let token = try? keychainStore.readString(for: tokenKey), !token.isEmpty else {
            recordDiagnostic("recording_missing_token", metadata: ["hasToken": "false"])
            recordingStatus = .error(String(localized: "record.error.missingToken"))
            return
        }

        do {
            recordDiagnostic("transcription_started", metadata: ["hasToken": "true"])
            let transcribedText = try await transcriptionClient.transcribe(audioFileURL: audioURL, baseURL: aiBuilderEndpoint, token: token)
            recordDiagnostic("transcription_succeeded", metadata: ["characterCount": "\(transcribedText.count)"])
            transcript = transcribedText
            openCodeSendStatus = .idle
            transcriptHistory.add(transcribedText)
            copyTranscript()
            recordingStatus = .ready
        } catch {
            recordDiagnostic(transcriptionFailureEventName(for: error), metadata: diagnosticMetadata(for: error))
            recordingStatus = .error(String(localized: "record.error.transcriptionFailed"))
        }
    }

    func copyTranscript() {
        guard canCopyTranscript else {
            recordDiagnostic("clipboard_copy_skipped", metadata: ["hasTranscript": "false"])
            return
        }
        do {
            try clipboardWriter.write(transcript)
            recordDiagnostic("clipboard_copy_succeeded", metadata: ["characterCount": "\(transcript.count)"])
            lastClipboardStatus = String(localized: "record.clipboard.copied")
        } catch {
            recordDiagnostic("clipboard_copy_failed", metadata: diagnosticMetadata(for: error))
            lastClipboardStatus = String(localized: "record.clipboard.failed")
        }
    }

    func restorePreviousTranscript() {
        guard let previousText = transcriptHistory.restorePrevious(currentText: transcript) else { return }
        transcript = previousText
    }

    func saveOpenCodePassword(_ password: String) {
        let trimmed = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try keychainStore.saveString(trimmed, for: openCodePasswordKey)
            hasSavedOpenCodePassword = true
            openCodeSendStatus = .idle
        } catch {
            openCodeSendStatus = .failed(String(localized: "settings.openCode.saveFailed"))
        }
    }

    func clearOpenCodeConfig() {
        do {
            try keychainStore.deleteString(for: openCodePasswordKey)
        } catch {
            openCodeSendStatus = .failed(String(localized: "settings.openCode.clearFailed"))
            return
        }
        openCodeServerURL = OpenCodeClient.defaultServerURL
        openCodeUsername = OpenCodeClient.defaultUsername
        hasSavedOpenCodePassword = false
        openCodeSendStatus = .idle
    }

    private func recordDiagnostic(_ name: String, metadata: [String: String] = [:]) {
        diagnostics.record(RecordingDiagnosticEvent(name, metadata: metadata))
    }

    private func diagnosticMetadata(for error: Error) -> [String: String] {
        ["errorType": String(describing: type(of: error))]
    }

    private func audioFileMetadata(for url: URL) -> [String: String] {
        let byteCount = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
        return ["byteCount": byteCount.map(String.init) ?? "unknown"]
    }

    private func transcriptionFailureEventName(for error: Error) -> String {
        if let transcriptionError = error as? AIBuilderTranscriptionError {
            switch transcriptionError {
            case .invalidBaseURL, .requestFailed:
                return "transcription_upload_failed"
            case .invalidResponse, .emptyTranscript:
                return "transcription_response_failed"
            }
        }
        if error is DecodingError {
            return "transcription_response_failed"
        }
        return "transcription_upload_failed"
    }

    func sendTranscriptToOpenCode() async {
        guard canCopyTranscript else { return }
        guard isOpenCodeConfigured, let password = try? keychainStore.readString(for: openCodePasswordKey), !password.isEmpty else {
            recordDiagnostic("opencode_send_failed", metadata: ["reason": "notConfigured"])
            openCodeSendStatus = .failed(String(localized: "record.openCode.error.notConfigured"))
            return
        }

        openCodeSendStatus = .sending
        recordDiagnostic("opencode_send_started", metadata: ["characterCount": "\(transcript.count)"])
        do {
            try await openCodeClient.sendTranscript(
                transcript,
                serverURL: openCodeServerURL.trimmingCharacters(in: .whitespacesAndNewlines),
                username: openCodeUsername.trimmingCharacters(in: .whitespacesAndNewlines),
                password: password
            )
            recordDiagnostic("opencode_send_succeeded", metadata: ["characterCount": "\(transcript.count)"])
            openCodeSendStatus = .success
        } catch {
            recordDiagnostic("opencode_send_failed", metadata: diagnosticMetadata(for: error))
            openCodeSendStatus = .failed(String(localized: "record.openCode.error.sendFailed"))
        }
    }
}
