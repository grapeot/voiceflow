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
        openCodeClient: OpenCodeSending? = nil
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
            recordingStatus = .error(String(localized: "record.error.missingToken"))
            return
        }

        recordingStatus = .requestingPermission
        guard await audioRecorder.requestPermission() else {
            recordingStatus = .error(String(localized: "record.error.microphoneDenied"))
            return
        }

        do {
            transcript = ""
            lastClipboardStatus = nil
            openCodeSendStatus = .idle
            try await audioRecorder.startRecording()
            recordingStatus = .recording
        } catch {
            recordingStatus = .error(String(localized: "record.error.recordingFailed"))
        }
    }

    func stopRecording() async {
        guard recordingStatus == .recording else { return }
        recordingStatus = .transcribing

        do {
            let audioURL = try await audioRecorder.stopRecording()
            defer { try? FileManager.default.removeItem(at: audioURL) }

            guard let token = try? keychainStore.readString(for: tokenKey), !token.isEmpty else {
                recordingStatus = .error(String(localized: "record.error.missingToken"))
                return
            }

            let transcribedText = try await transcriptionClient.transcribe(audioFileURL: audioURL, baseURL: aiBuilderEndpoint, token: token)
            transcript = transcribedText
            openCodeSendStatus = .idle
            transcriptHistory.add(transcribedText)
            copyTranscript()
            recordingStatus = .ready
        } catch {
            recordingStatus = .error(String(localized: "record.error.transcriptionFailed"))
        }
    }

    func copyTranscript() {
        guard canCopyTranscript else { return }
        do {
            try clipboardWriter.write(transcript)
            lastClipboardStatus = String(localized: "record.clipboard.copied")
        } catch {
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

    func sendTranscriptToOpenCode() async {
        guard canCopyTranscript else { return }
        guard isOpenCodeConfigured, let password = try? keychainStore.readString(for: openCodePasswordKey), !password.isEmpty else {
            openCodeSendStatus = .failed(String(localized: "record.openCode.error.notConfigured"))
            return
        }

        openCodeSendStatus = .sending
        do {
            try await openCodeClient.sendTranscript(
                transcript,
                serverURL: openCodeServerURL.trimmingCharacters(in: .whitespacesAndNewlines),
                username: openCodeUsername.trimmingCharacters(in: .whitespacesAndNewlines),
                password: password
            )
            openCodeSendStatus = .success
        } catch {
            openCodeSendStatus = .failed(String(localized: "record.openCode.error.sendFailed"))
        }
    }
}
