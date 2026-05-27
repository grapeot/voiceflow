import Combine
import Foundation

@MainActor
final class AppState: ObservableObject {
    enum AppTab: Hashable {
        case record
        case settings
    }

    enum RecordingStatus: Equatable {
        case idle
        case requestingPermission
        case recording
        case transcribing
        case ready

        var localizedKey: String {
            switch self {
            case .idle:
                "record.status.idle"
            case .requestingPermission:
                "record.status.requestingPermission"
            case .recording:
                "record.status.recording"
            case .transcribing:
                "record.status.transcribing"
            case .ready:
                "record.status.ready"
            }
        }

        var indicatorAccessibilityValue: String {
            switch self {
            case .idle:
                "idle"
            case .requestingPermission:
                "requestingPermission"
            case .recording:
                "recording"
            case .transcribing:
                "transcribing"
            case .ready:
                "ready"
            }
        }
    }

    @Published var recordingStatus: RecordingStatus = .idle
    @Published var selectedTab: AppTab = .record
    @Published private(set) var pendingDeepLinkStartRecording = false
    @Published var recordErrorAlertKey: String?
    @Published var transcript: String = ""
    @Published var transcriptHistory = TranscriptHistory()
    @Published var hasSavedAIBuilderToken = false
    @Published var openCodeServerURL: String {
        didSet {
            UserDefaults.standard.set(openCodeServerURL, forKey: Self.openCodeServerURLDefaultsKey)
            if oldValue != openCodeServerURL {
                openCodeConnectionStatus = .untested
            }
        }
    }
    @Published var openCodeUsername: String {
        didSet {
            UserDefaults.standard.set(openCodeUsername, forKey: Self.openCodeUsernameDefaultsKey)
            if oldValue != openCodeUsername {
                openCodeConnectionStatus = .untested
            }
        }
    }
    @Published var hasSavedOpenCodePassword = false
    @Published var openCodeSendStatus: OpenCodeSendStatus = .idle
    @Published var openCodeConnectionStatus: ConnectionStatus = .untested
    @Published var lastClipboardStatusKey: String?
    @Published private(set) var lastSavedRecording: SavedRecordingInfo?
    @Published var shouldPresentSavedRecordingAlert = false
    @Published var connectionStatus: ConnectionStatus = .untested
    @Published var appLanguage: AppLanguage {
        didSet { UserDefaults.standard.set(appLanguage.rawValue, forKey: Self.appLanguageDefaultsKey) }
    }

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
    private static let appLanguageDefaultsKey = "appLanguage"
    private var lastRecordingURL: URL?

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
        if isUITestMode, ProcessInfo.processInfo.arguments.contains("-uiTestResetPreferences") {
            UserDefaults.standard.removeObject(forKey: Self.openCodeServerURLDefaultsKey)
            UserDefaults.standard.removeObject(forKey: Self.openCodeUsernameDefaultsKey)
            UserDefaults.standard.removeObject(forKey: Self.appLanguageDefaultsKey)
        }
        self.openCodeServerURL = UserDefaults.standard.string(forKey: Self.openCodeServerURLDefaultsKey) ?? OpenCodeClient.defaultServerURL
        self.openCodeUsername = UserDefaults.standard.string(forKey: Self.openCodeUsernameDefaultsKey) ?? OpenCodeClient.defaultUsername
        let savedLanguage = UserDefaults.standard.string(forKey: Self.appLanguageDefaultsKey).flatMap(AppLanguage.init(rawValue:))
        self.appLanguage = savedLanguage ?? .system
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
        if let openCodeClient {
            self.openCodeClient = openCodeClient
        } else if isUITestMode, ProcessInfo.processInfo.arguments.contains("-uiTestOpenCodeConnectionFailure") {
            self.openCodeClient = MockOpenCodeClient(
                result: .success(()),
                testConnectionResult: .failure(OpenCodeClientError.sessionCreationFailed)
            )
        } else if isUITestMode {
            self.openCodeClient = MockOpenCodeClient(result: .success(()))
        } else {
            self.openCodeClient = OpenCodeClient()
        }
        self.diagnostics = diagnostics ?? (isUITestMode ? InMemoryRecordingDiagnostics() : OSRecordingDiagnostics())
        if isUITestMode, ProcessInfo.processInfo.arguments.contains("-uiTestSavedToken") {
            try? self.keychainStore.saveString("fake-ui-token", for: tokenKey)
        }
        if isUITestMode, ProcessInfo.processInfo.arguments.contains("-uiTestSavedOpenCode") {
            self.openCodeServerURL = OpenCodeClient.defaultServerURL
            self.openCodeUsername = OpenCodeClient.defaultUsername
            try? self.keychainStore.saveString("fake-opencode-password", for: openCodePasswordKey)
            self.openCodeConnectionStatus = .success
        }
        self.hasSavedAIBuilderToken = (try? self.keychainStore.readString(for: tokenKey)) != nil
        self.hasSavedOpenCodePassword = (try? self.keychainStore.readString(for: openCodePasswordKey)) != nil
        if isUITestMode, ProcessInfo.processInfo.arguments.contains("-uiTestDeepLinkRecord") {
            handleIncomingURL(URL(string: "voiceflow://record")!)
        }
    }

    func handleIncomingURL(_ url: URL) {
        recordDiagnostic("deeplink_received", metadata: DeepLink.diagnosticMetadata(for: url))
        guard DeepLink.parse(url) == .startRecording else {
            recordDiagnostic("deeplink_ignored", metadata: DeepLink.diagnosticMetadata(for: url))
            return
        }
        selectedTab = .record
        pendingDeepLinkStartRecording = true
    }

    func consumePendingDeepLinkStartRecordingIfNeeded() async {
        guard pendingDeepLinkStartRecording else { return }
        pendingDeepLinkStartRecording = false
        await startRecording()
    }

    var canCopyTranscript: Bool {
        !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canSendToOpenCode: Bool {
        canCopyTranscript && isOpenCodeConfigured && openCodeConnectionStatus == .success
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

    var canNavigateTranscriptHistory: Bool {
        recordingStatus == .idle || recordingStatus == .ready
    }

    var canNavigatePreviousTranscript: Bool {
        canNavigateTranscriptHistory && transcriptHistory.hasPrevious
    }

    var canNavigateNextTranscript: Bool {
        canNavigateTranscriptHistory && transcriptHistory.hasNext
    }

    var canSaveRecording: Bool {
        canNavigateTranscriptHistory && lastRecordingFileExists
    }

    var canResendRecording: Bool {
        canNavigateTranscriptHistory && lastRecordingFileExists && hasSavedAIBuilderToken
    }

    private var lastRecordingFileExists: Bool {
        guard let lastRecordingURL else { return false }
        return FileManager.default.fileExists(atPath: lastRecordingURL.path)
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
            connectionStatus = .failed("settings.connection.saveFailed", nil)
        }
    }

    func clearAIBuilderToken() {
        do {
            try keychainStore.deleteString(for: tokenKey)
        } catch {
            connectionStatus = .failed("settings.connection.clearFailed", nil)
            return
        }
        hasSavedAIBuilderToken = false
        connectionStatus = .untested
    }

    func testAIBuilderConnection() async {
        guard let token = try? keychainStore.readString(for: tokenKey), !token.isEmpty else {
            connectionStatus = .failed("settings.connection.missingToken", nil)
            return
        }

        connectionStatus = .testing
        do {
            try await aiBuilderClient.testConnection(baseURL: aiBuilderEndpoint, token: token)
            connectionStatus = .success
        } catch {
            connectionStatus = .failed("settings.connection.failed", userFacingErrorDetail(for: error))
        }
    }

    func startRecording() async {
        guard hasSavedAIBuilderToken else {
            recordDiagnostic("recording_missing_token", metadata: ["hasToken": "false"])
            presentRecordError("record.error.missingToken")
            return
        }

        recordingStatus = .requestingPermission
        recordDiagnostic("recording_permission_request_started")
        guard await audioRecorder.requestPermission() else {
            recordDiagnostic("recording_permission_denied")
            presentRecordError("record.error.microphoneDenied")
            return
        }

        do {
            transcript = ""
            lastClipboardStatusKey = nil
            lastSavedRecording = nil
            shouldPresentSavedRecordingAlert = false
            openCodeSendStatus = .idle
            recordDiagnostic("recording_start_requested", metadata: ["hasToken": "true"])
            try await audioRecorder.startRecording()
            recordDiagnostic("recording_start_succeeded")
            recordingStatus = .recording
        } catch {
            recordDiagnostic("recording_start_failed", metadata: diagnosticMetadata(for: error))
            presentRecordError("record.error.recordingFailed")
        }
    }

    func dismissRecordError() {
        recordErrorAlertKey = nil
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
            presentRecordError("record.error.transcriptionFailed")
            return
        }

        let audioMetadata = audioFileMetadata(for: audioURL)
        recordDiagnostic("recording_stop_succeeded", metadata: audioMetadata)
        if audioMetadata["byteCount"] == "0" {
            try? FileManager.default.removeItem(at: audioURL)
            recordDiagnostic("recording_audio_file_empty")
            presentRecordError("record.error.transcriptionFailed")
            return
        }

        do {
            lastRecordingURL = try persistLastRecording(from: audioURL)
        } catch {
            try? FileManager.default.removeItem(at: audioURL)
            recordDiagnostic("recording_persist_failed", metadata: diagnosticMetadata(for: error))
            presentRecordError("record.error.transcriptionFailed")
            return
        }
        try? FileManager.default.removeItem(at: audioURL)

        await finishTranscriptionFromLastRecording()
    }

    func copyTranscript() {
        guard canCopyTranscript else {
            recordDiagnostic("clipboard_copy_skipped", metadata: ["hasTranscript": "false"])
            return
        }
        do {
            try clipboardWriter.write(transcript)
            recordDiagnostic("clipboard_copy_succeeded", metadata: ["characterCount": "\(transcript.count)"])
            lastClipboardStatusKey = "record.clipboard.copied"
        } catch {
            recordDiagnostic("clipboard_copy_failed", metadata: diagnosticMetadata(for: error))
            lastClipboardStatusKey = "record.clipboard.failed"
        }
    }

    func navigatePreviousTranscript() {
        guard let previousText = transcriptHistory.navigatePrevious() else { return }
        transcript = previousText
        openCodeSendStatus = .idle
        lastClipboardStatusKey = nil
    }

    func navigateNextTranscript() {
        guard let nextText = transcriptHistory.navigateNext() else { return }
        transcript = nextText
        openCodeSendStatus = .idle
        lastClipboardStatusKey = nil
    }

    func saveCurrentRecording() {
        guard canSaveRecording, let sourceURL = lastRecordingURL else { return }

        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let destinationURL = RecordingFileSaver.makeDestinationURL(in: documentsPath)

        do {
            try RecordingFileSaver.saveRecording(from: sourceURL, to: destinationURL)
            let savedRecording = SavedRecordingInfo(
                fileName: destinationURL.lastPathComponent,
                fileURL: destinationURL
            )
            lastSavedRecording = savedRecording
            shouldPresentSavedRecordingAlert = true
            recordDiagnostic("recording_saved", metadata: ["fileName": savedRecording.fileName])
        } catch {
            recordDiagnostic("recording_save_failed", metadata: diagnosticMetadata(for: error))
            lastSavedRecording = nil
            shouldPresentSavedRecordingAlert = false
            lastClipboardStatusKey = "record.save.failed"
        }
    }

    func acknowledgeSavedRecordingAlert() {
        shouldPresentSavedRecordingAlert = false
    }

    func resendLastRecording() async {
        guard canResendRecording else { return }
        recordingStatus = .transcribing
        openCodeSendStatus = .idle
        lastClipboardStatusKey = nil
        recordDiagnostic("recording_resend_requested")
        await finishTranscriptionFromLastRecording()
    }

    func saveOpenCodePassword(_ password: String) {
        let trimmed = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try keychainStore.saveString(trimmed, for: openCodePasswordKey)
            hasSavedOpenCodePassword = true
            openCodeSendStatus = .idle
            openCodeConnectionStatus = .untested
        } catch {
            openCodeSendStatus = .failed("settings.openCode.saveFailed")
        }
    }

    func clearOpenCodePassword() {
        do {
            try keychainStore.deleteString(for: openCodePasswordKey)
        } catch {
            openCodeSendStatus = .failed("settings.openCode.clearFailed")
            return
        }
        hasSavedOpenCodePassword = false
        openCodeSendStatus = .idle
        openCodeConnectionStatus = .untested
    }

    func testOpenCodeConnection() async {
        guard isOpenCodeConfigured, let password = try? keychainStore.readString(for: openCodePasswordKey), !password.isEmpty else {
            openCodeConnectionStatus = .failed("settings.openCode.connection.missingConfig", nil)
            return
        }

        openCodeConnectionStatus = .testing
        do {
            try await openCodeClient.testConnection(
                serverURL: openCodeServerURL.trimmingCharacters(in: .whitespacesAndNewlines),
                username: openCodeUsername.trimmingCharacters(in: .whitespacesAndNewlines),
                password: password
            )
            openCodeConnectionStatus = .success
        } catch {
            openCodeConnectionStatus = .failed("settings.openCode.connection.failed", userFacingErrorDetail(for: error))
        }
    }

    private func presentRecordError(_ key: String) {
        recordErrorAlertKey = key
        recordingStatus = .idle
    }

    private func recordDiagnostic(_ name: String, metadata: [String: String] = [:]) {
        diagnostics.record(RecordingDiagnosticEvent(name, metadata: metadata))
    }

    private func diagnosticMetadata(for error: Error) -> [String: String] {
        DiagnosticErrorMetadata.metadata(for: error)
    }

    private func userFacingErrorDetail(for error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription,
           !description.isEmpty {
            return description
        }
        let description = error.localizedDescription
        return description.isEmpty ? String(describing: error) : description
    }

    private func audioFileMetadata(for url: URL) -> [String: String] {
        let byteCount = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
        return ["byteCount": byteCount.map(String.init) ?? "unknown"]
    }

    private func persistLastRecording(from temporaryURL: URL) throws -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceFlow", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destinationURL = directory.appendingPathComponent("last-recording.wav")
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.copyItem(at: temporaryURL, to: destinationURL)
        return destinationURL
    }

    private func finishTranscriptionFromLastRecording() async {
        guard let audioURL = lastRecordingURL else {
            presentRecordError("record.error.transcriptionFailed")
            return
        }

        guard let token = try? keychainStore.readString(for: tokenKey), !token.isEmpty else {
            recordDiagnostic("recording_missing_token", metadata: ["hasToken": "false"])
            presentRecordError("record.error.missingToken")
            return
        }

        do {
            recordDiagnostic("transcription_started", metadata: ["hasToken": "true"])
            let transcribedText = try await transcriptionClient.transcribe(
                audioFileURL: audioURL,
                baseURL: aiBuilderEndpoint,
                token: token
            )
            recordDiagnostic("transcription_succeeded", metadata: ["characterCount": "\(transcribedText.count)"])
            transcript = transcribedText
            openCodeSendStatus = .idle
            transcriptHistory.add(transcribedText)
            copyTranscript()
            recordingStatus = .ready
        } catch {
            recordDiagnostic(transcriptionFailureEventName(for: error), metadata: diagnosticMetadata(for: error))
            presentRecordError("record.error.transcriptionFailed")
        }
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
            openCodeSendStatus = .failed("record.openCode.error.notConfigured")
            return
        }
        guard openCodeConnectionStatus == .success else {
            recordDiagnostic("opencode_send_failed", metadata: ["reason": "connectionNotVerified"])
            openCodeSendStatus = .failed("record.openCode.error.connectionNotVerified")
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
            openCodeSendStatus = .failed("record.openCode.error.sendFailed")
        }
    }
}
