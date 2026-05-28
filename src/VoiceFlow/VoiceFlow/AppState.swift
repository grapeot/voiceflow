import Combine
import Foundation
import SwiftUI

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
    @Published private(set) var streamConnectionPhase: RealtimeConnectionPhase = .disconnected
    /// Long-lived status the user should keep seeing — currently
    /// "Reconnecting…" while the stream is auto-recovering and
    /// "Stream disconnected." after recovery fails. Set this directly only
    /// for states that genuinely persist; transient confirmations like
    /// "Stream restored." go through `flashTransientStreamCaption(_:)`.
    @Published private(set) var persistentStreamCaptionKey: String?
    /// Briefly overlaid on top of `persistentStreamCaptionKey`. Currently
    /// used for "Stream restored.": we want to acknowledge the recovery but
    /// not leave that confirmation on screen indefinitely. After
    /// `transientStreamCaptionDuration` seconds it clears itself, revealing
    /// whatever `persistentStreamCaptionKey` currently is (which, by then,
    /// is usually nil — i.e. silent normal operation).
    @Published private(set) var transientStreamCaptionKey: String?
    /// What RecordView reads. Transient layer wins so a flash confirmation
    /// hides the underlying state; once the flash clears, the persistent
    /// layer (which may itself be nil) shows through.
    var streamStatusCaptionKey: String? {
        transientStreamCaptionKey ?? persistentStreamCaptionKey
    }
    private var transientStreamCaptionTask: Task<Void, Never>?
    private let transientStreamCaptionDuration: Duration = .seconds(3)
    @Published private(set) var recordingTimerText = "00:00"
    /// Smoothed 0…1 microphone level. Driven by the mic PCM tap while
    /// recording; falls back to 0 when idle/transcribing/error so the
    /// waveform reads as quiet rather than frozen.
    @Published private(set) var audioLevel: Float = 0
    @Published var appLanguage: AppLanguage {
        didSet { UserDefaults.standard.set(appLanguage.rawValue, forKey: Self.appLanguageDefaultsKey) }
    }

    let aiBuilderEndpoint = "https://space.ai-builders.com/backend"
    private let keychainStore: KeychainStoring
    private let aiBuilderClient: AIBuilderConnectionTesting
    private let audioRecorder: AudioRecording
    private let transcriptionClient: AIBuilderTranscribing
    private let realtimeTranscriptionClient: RealtimeTranscribing
    private let clipboardWriter: ClipboardWriting
    private let openCodeClient: OpenCodeSending
    private let diagnostics: RecordingDiagnosticsReporting
    private let tokenKey = "aiBuilderToken"
    private let openCodePasswordKey = "openCodePassword"
    private static let openCodeServerURLDefaultsKey = "openCodeServerURL"
    private static let openCodeUsernameDefaultsKey = "openCodeUsername"
    private static let appLanguageDefaultsKey = "appLanguage"
    private var lastRecordingURL: URL?
    private var recordingTimerStartDate: Date?
    private var recordingTimer: Timer?
    private var liveTranscriptionSession: (any RealtimeLiveTranscriptionSession)?
    private var audioChunkEncoder = AudioChunkEncoder()
    private var streamHeartbeatTask: Task<Void, Never>?
    private var lastStreamClipboardHash: Int?
    private var lastStreamClipboardUpdate: Date?
    private var userEditedTranscriptDuringStream = false
    private var isTranscriptionTeardown = false

    private static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    init(
        keychainStore: KeychainStoring? = nil,
        aiBuilderClient: AIBuilderConnectionTesting? = nil,
        audioRecorder: AudioRecording? = nil,
        transcriptionClient: AIBuilderTranscribing? = nil,
        realtimeTranscriptionClient: RealtimeTranscribing? = nil,
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
        self.realtimeTranscriptionClient = realtimeTranscriptionClient ?? ((isUITestMode || Self.isRunningUnitTests) ? MockRealtimeTranscriptionClient(liveResult: .success("Mock transcription")) : RealtimeTranscriptionClient())
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
        if isUITestMode {
            applyUITestLaunchArgumentSeeds()
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

    /// Clears UI-test state between XCTest cases without relaunching (only when `-uiTestMode`).
    func resetForUITest() async {
        guard ProcessInfo.processInfo.arguments.contains("-uiTestMode") else { return }

        await cancelLiveTranscriptionSession()
        stopRecordingTimer()
        recordErrorAlertKey = nil
        pendingDeepLinkStartRecording = false
        transcript = ""
        transcriptHistory = TranscriptHistory()
        userEditedTranscriptDuringStream = false
        lastClipboardStatusKey = nil
        clearStreamCaptions()
        lastSavedRecording = nil
        shouldPresentSavedRecordingAlert = false
        openCodeSendStatus = .idle
        connectionStatus = .untested
        openCodeConnectionStatus = .untested
        recordingStatus = .idle
        streamConnectionPhase = .disconnected
        recordingTimerText = "00:00"
        audioLevel = 0
        lastRecordingURL = nil
        lastStreamClipboardHash = nil
        lastStreamClipboardUpdate = nil
        isTranscriptionTeardown = false
        selectedTab = .record
        audioChunkEncoder = AudioChunkEncoder()

        UserDefaults.standard.removeObject(forKey: Self.openCodeServerURLDefaultsKey)
        UserDefaults.standard.removeObject(forKey: Self.openCodeUsernameDefaultsKey)
        UserDefaults.standard.removeObject(forKey: Self.appLanguageDefaultsKey)
        openCodeServerURL = OpenCodeClient.defaultServerURL
        openCodeUsername = OpenCodeClient.defaultUsername
        appLanguage = .system

        try? keychainStore.deleteString(for: tokenKey)
        try? keychainStore.deleteString(for: openCodePasswordKey)
        hasSavedAIBuilderToken = false
        hasSavedOpenCodePassword = false

        applyUITestLaunchArgumentSeeds()
    }

    private func applyUITestLaunchArgumentSeeds() {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-uiTestSavedToken") {
            try? keychainStore.saveString("fake-ui-token", for: tokenKey)
            hasSavedAIBuilderToken = true
        }
        if arguments.contains("-uiTestSavedOpenCode") {
            openCodeServerURL = OpenCodeClient.defaultServerURL
            openCodeUsername = OpenCodeClient.defaultUsername
            try? keychainStore.saveString("fake-opencode-password", for: openCodePasswordKey)
            hasSavedOpenCodePassword = true
            openCodeConnectionStatus = .success
        }
        if arguments.contains("-uiTestOpenCodeConnectionFailure") {
            openCodeConnectionStatus = .untested
        }
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

        guard let token = try? keychainStore.readString(for: tokenKey), !token.isEmpty else {
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
            userEditedTranscriptDuringStream = false
            lastClipboardStatusKey = nil
            clearStreamCaptions()
            lastSavedRecording = nil
            shouldPresentSavedRecordingAlert = false
            openCodeSendStatus = .idle
            audioChunkEncoder = AudioChunkEncoder()
            streamConnectionPhase = .connecting
            recordDiagnostic("recording_start_requested", metadata: ["hasToken": "true", "mode": "stream"])

            liveTranscriptionSession = try await realtimeTranscriptionClient.beginLiveSession(
                baseURL: aiBuilderEndpoint,
                token: token,
                model: RealtimeTranscriptionConfig.defaultModel,
                onEvent: { [weak self] event in
                    guard let self else { return }
                    Task { @MainActor in
                        self.handleStreamEvent(event)
                    }
                }
            )
            startStreamHeartbeat()

            try await audioRecorder.startRecording { [weak self] chunk in
                Task { await self?.handleCapturedPCMChunk(chunk) }
            }
            recordDiagnostic("recording_start_succeeded")
            resetRecordingTimer()
            startRecordingTimer()
            recordingStatus = .recording
        } catch {
            await cancelLiveTranscriptionSession()
            recordDiagnostic("recording_start_failed", metadata: diagnosticMetadata(for: error))
            resetRecordingTimer()
            presentRecordError("record.error.recordingFailed")
        }
    }

    func dismissRecordError() {
        recordErrorAlertKey = nil
    }

    func stopRecording() async {
        guard recordingStatus == .recording else { return }
        stopRecordingTimer()
        recordingStatus = .transcribing
        recordDiagnostic("recording_stop_requested")

        let audioURL: URL
        do {
            audioURL = try await audioRecorder.stopRecording()
        } catch {
            await cancelLiveTranscriptionSession()
            recordDiagnostic("recording_stop_failed", metadata: diagnosticMetadata(for: error))
            presentRecordError("record.error.transcriptionFailed")
            return
        }

        let audioMetadata = audioFileMetadata(for: audioURL)
        recordDiagnostic("recording_stop_succeeded", metadata: audioMetadata)
        if audioMetadata["byteCount"] == "0" {
            try? FileManager.default.removeItem(at: audioURL)
            await cancelLiveTranscriptionSession()
            recordDiagnostic("recording_audio_file_empty")
            presentRecordError("record.error.transcriptionFailed")
            return
        }

        do {
            lastRecordingURL = try persistLastRecording(from: audioURL)
        } catch {
            try? FileManager.default.removeItem(at: audioURL)
            await cancelLiveTranscriptionSession()
            recordDiagnostic("recording_persist_failed", metadata: diagnosticMetadata(for: error))
            presentRecordError("record.error.transcriptionFailed")
            return
        }
        try? FileManager.default.removeItem(at: audioURL)

        await flushRemainingAudioChunks()
        await finishLiveTranscriptionSession()
    }

    func handleScenePhaseChange(to phase: ScenePhase) async {
        switch phase {
        case .active:
            await liveTranscriptionSession?.heartbeat()
        case .background:
            stopStreamHeartbeat()
            await liveTranscriptionSession?.cancel()
            liveTranscriptionSession = nil
            streamConnectionPhase = .disconnected
            clearStreamCaptions()
        default:
            break
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
        if let bulkText = await finishTranscriptionFromLastRecording(presentErrorOnFailure: true) {
            transcript = bulkText
            transcriptHistory.add(bulkText)
            copyTranscript()
            recordingStatus = .ready
        }
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
        stopRecordingTimer()
    }

    /// Set the long-lived stream caption. Pass `nil` to clear only the
    /// persistent layer (transient overlay stays visible if active).
    private func setPersistentStreamCaption(_ key: String?) {
        persistentStreamCaptionKey = key
    }

    /// Flash a short confirmation for `transientStreamCaptionDuration`.
    /// After the delay, the transient layer clears itself, exposing the
    /// current persistent caption (which may have changed in the meantime).
    /// Multiple flashes restart the timer rather than overlap.
    private func flashTransientStreamCaption(_ key: String) {
        transientStreamCaptionTask?.cancel()
        transientStreamCaptionKey = key
        transientStreamCaptionTask = Task { [weak self, duration = transientStreamCaptionDuration] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self else { return }
            await MainActor.run { self.transientStreamCaptionKey = nil }
        }
    }

    /// Clear both caption layers (used by teardown / reset paths).
    private func clearStreamCaptions() {
        transientStreamCaptionTask?.cancel()
        transientStreamCaptionTask = nil
        transientStreamCaptionKey = nil
        persistentStreamCaptionKey = nil
    }

    private func resetRecordingTimer() {
        stopRecordingTimer()
        recordingTimerText = RecordingTimerFormatter.format(elapsedSeconds: 0)
    }

    private func startRecordingTimer() {
        recordingTimerStartDate = Date()
        recordingTimerText = RecordingTimerFormatter.format(elapsedSeconds: 0)
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.updateRecordingTimerText()
            }
        }
    }

    private func stopRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingTimerStartDate = nil
    }

    private func updateRecordingTimerText() {
        guard let recordingTimerStartDate else { return }
        let elapsed = Int(Date().timeIntervalSince(recordingTimerStartDate))
        recordingTimerText = RecordingTimerFormatter.format(elapsedSeconds: elapsed)
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

    private func finishTranscriptionFromLastRecording(presentErrorOnFailure: Bool = true) async -> String? {
        guard let audioURL = lastRecordingURL else {
            if presentErrorOnFailure {
                presentRecordError("record.error.transcriptionFailed")
            }
            return nil
        }

        guard let token = try? keychainStore.readString(for: tokenKey), !token.isEmpty else {
            recordDiagnostic("recording_missing_token", metadata: ["hasToken": "false"])
            if presentErrorOnFailure {
                presentRecordError("record.error.missingToken")
            }
            return nil
        }

        do {
            recordDiagnostic("transcription_started", metadata: ["hasToken": "true", "mode": "bulk"])
            let pcmData = try PCM16WAVWriter.readPCM(from: audioURL)
            let transcribedText = try await realtimeTranscriptionClient.transcribeBulkPCM(
                pcmData: pcmData,
                baseURL: aiBuilderEndpoint,
                token: token,
                model: RealtimeTranscriptionConfig.defaultModel
            ) { [weak self] partial in
                guard let self else { return }
                Task { @MainActor in
                    self.transcript = partial
                }
            }
            recordDiagnostic("transcription_succeeded", metadata: ["characterCount": "\(transcribedText.count)", "mode": "bulk"])
            return transcribedText
        } catch {
            recordDiagnostic(transcriptionFailureEventName(for: error), metadata: diagnosticMetadata(for: error))
            if presentErrorOnFailure {
                presentRecordError("record.error.transcriptionFailed")
            }
            return nil
        }
    }

    private func handleStreamEvent(_ event: RealtimeTranscriptEvent) {
        switch event {
        case .status(let status):
            switch status {
            case .connected, .connecting:
                if recordingStatus == .recording {
                    streamConnectionPhase = .connected
                    if persistentStreamCaptionKey == "record.status.reconnecting" {
                        setPersistentStreamCaption(nil)
                        flashTransientStreamCaption("record.status.reconnected")
                    }
                }
            case .generating:
                streamConnectionPhase = .generating
            case .idle:
                streamConnectionPhase = .disconnected
            }
        case .textDelta(let content, let isNewResponse):
            guard recordingStatus != .recording else { return }
            if !userEditedTranscriptDuringStream || isNewResponse {
                transcript = TranscriptDeltaReducer.apply(
                    current: transcript,
                    content: content,
                    isNewResponse: isNewResponse
                )
                throttledStreamClipboardWrite(transcript)
            }
        case .error(let message):
            if RealtimeTranscriptionSupport.isRecoverableBufferTooSmallError(message),
               recordingStatus == .recording || isTranscriptionTeardown {
                return
            }
            if isTranscriptionTeardown || recordingStatus == .transcribing {
                recordDiagnostic(
                    "transcription_stream_error_ignored",
                    metadata: ["reason": message, "phase": isTranscriptionTeardown ? "teardown" : "transcribing"]
                )
                if recordingStatus == .transcribing, !isTranscriptionTeardown {
                    setPersistentStreamCaption("record.error.streamDisconnected")
                }
                return
            }
            recordDiagnostic("transcription_stream_error", metadata: ["reason": message])
            streamConnectionPhase = .disconnected
            if recordingStatus == .recording {
                setPersistentStreamCaption("record.status.reconnecting")
            } else if !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                setPersistentStreamCaption("record.error.streamDisconnected")
            } else {
                presentRecordError("record.error.transcriptionFailed")
            }
        case .disconnected:
            if isTranscriptionTeardown {
                return
            }
            streamConnectionPhase = .disconnected
            if recordingStatus == .recording {
                setPersistentStreamCaption("record.status.reconnecting")
            }
        case .recoveryStarted:
            streamConnectionPhase = .recovering
            if recordingStatus == .recording {
                setPersistentStreamCaption("record.status.reconnecting")
            }
        case .recoveryFailed(let message):
            recordDiagnostic("transcription_stream_recovery_failed", metadata: ["reason": message])
            streamConnectionPhase = .disconnected
            if recordingStatus == .recording {
                setPersistentStreamCaption("record.error.streamDisconnected")
            } else if !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                setPersistentStreamCaption("record.error.streamDisconnected")
            }
        }
    }

    private func handleCapturedPCMChunk(_ chunk: Data) async {
        updateAudioLevel(from: chunk)

        let chunks = audioChunkEncoder.append(chunk)
        for encodedChunk in chunks {
            await liveTranscriptionSession?.appendAudioChunk(encodedChunk)
        }
        if let session = liveTranscriptionSession {
            let phase = await session.connectionPhase
            streamConnectionPhase = phase
            if phase == .connected, persistentStreamCaptionKey == "record.status.reconnecting" {
                setPersistentStreamCaption(nil)
                flashTransientStreamCaption("record.status.reconnected")
            }
        }
    }

    /// Compute RMS of a PCM16 little-endian chunk, normalize to 0…1 with a
    /// gentle perceptual curve, and feed it into an exponential moving
    /// average so the waveform never jitters on short silences mid-syllable.
    private func updateAudioLevel(from chunk: Data) {
        let normalized = Self.normalizedLevel(fromPCM16LE: chunk)
        // 30 % new sample, 70 % carried — short attack, slow release.
        let smoothed = audioLevel * 0.7 + normalized * 0.3
        audioLevel = smoothed
    }

    private static func normalizedLevel(fromPCM16LE data: Data) -> Float {
        let sampleCount = data.count / 2
        guard sampleCount > 0 else { return 0 }

        let sumSquares: Double = data.withUnsafeBytes { raw -> Double in
            guard let base = raw.baseAddress else { return 0 }
            var accumulator: Double = 0
            // Read little-endian Int16 samples without assuming alignment.
            for i in 0..<sampleCount {
                let lo = Int16(base.load(fromByteOffset: i * 2,     as: UInt8.self))
                let hi = Int16(base.load(fromByteOffset: i * 2 + 1, as: UInt8.self))
                let raw = (hi << 8) | (lo & 0xFF)
                let sample = Double(raw) / 32768.0
                accumulator += sample * sample
            }
            return accumulator
        }

        let rms = sqrt(sumSquares / Double(sampleCount))

        // dB-based mapping. Typical phone-mic speech RMS sits around 0.03–0.15
        // (−30…−16 dB FS). Mapping [−50, −10] dB → [0, 1] makes quiet rooms
        // settle near 0 and a normal talking voice reach ~0.7–0.9 — closer to
        // what a user expects when watching a meter. A 0.9× tail keeps loud
        // syllables from pinning the visual ceiling so headroom stays visible.
        let dB = 20.0 * log10(max(rms, 1e-7))
        let minDB = -50.0
        let maxDB = -10.0
        let normalized = (dB - minDB) / (maxDB - minDB)
        let scaled = normalized * 0.9
        return Float(min(max(scaled, 0), 1))
    }

    private func flushRemainingAudioChunks() async {
        let remainder = audioChunkEncoder.flushRemainder()
        guard !remainder.isEmpty else { return }
        await liveTranscriptionSession?.appendAudioChunk(remainder)
    }

    private func updateTranscriptDuringFinalize(_ partial: String) {
        transcript = partial
        throttledStreamClipboardWrite(partial)
    }

    private func makeFinalizePartialHandler() -> @Sendable (String) -> Void {
        { [weak self] partial in
            Task { @MainActor [weak self] in
                guard let self else { return }
                updateTranscriptDuringFinalize(partial)
            }
        }
    }

    private func finishLiveTranscriptionSession() async {
        stopStreamHeartbeat()
        isTranscriptionTeardown = true
        defer { isTranscriptionTeardown = false }

        guard let session = liveTranscriptionSession else {
            recordDiagnostic("transcription_finalize_failed", metadata: ["reason": "noSession"])
            completeStopTranscriptionFailure(reason: "noSession")
            return
        }

        recordDiagnostic("transcription_finalize_started", metadata: ["hasToken": "true", "mode": "stream"])
        var streamText = ""
        do {
            streamText = try await session.finalize(onPartialTranscript: makeFinalizePartialHandler())
            recordDiagnostic(
                "transcription_finalize_stream_done",
                metadata: ["characterCount": "\(streamText.count)"]
            )
        } catch {
            recordDiagnostic(
                "transcription_finalize_stream_failed",
                metadata: diagnosticMetadata(for: error).merging(["reason": String(describing: error)]) { _, new in new }
            )
        }

        await cancelLiveTranscriptionSession()

        if isUsableTranscript(streamText) {
            completeStopTranscriptionSuccess(text: streamText, mode: "stream")
            return
        }

        let fallbackReason = streamText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "emptyStream" : "tooShort"
        recordDiagnostic("transcription_fallback_bulk", metadata: ["reason": fallbackReason])
        if let bulkText = await finishTranscriptionFromLastRecording(presentErrorOnFailure: false),
           isUsableTranscript(bulkText) {
            completeStopTranscriptionSuccess(text: bulkText, mode: "bulk")
            return
        }

        completeStopTranscriptionFailure(reason: "allPathsFailed")
    }

    private func isUsableTranscript(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).count > 3
    }

    private func completeStopTranscriptionSuccess(text: String, mode: String) {
        recordErrorAlertKey = nil
        transcript = text
        openCodeSendStatus = .idle
        streamConnectionPhase = .disconnected
        clearStreamCaptions()
        recordDiagnostic("transcription_succeeded", metadata: ["characterCount": "\(text.count)", "mode": mode])
        transcriptHistory.add(text)
        copyTranscript()
        recordingStatus = .ready
    }

    private func completeStopTranscriptionFailure(reason: String) {
        recordDiagnostic("transcription_stop_failed", metadata: ["reason": reason])
        if isUsableTranscript(transcript) {
            transcriptHistory.add(transcript)
            copyTranscript()
            recordingStatus = .ready
            setPersistentStreamCaption("record.error.streamDisconnected")
            return
        }
        presentRecordError("record.error.transcriptionFailed")
    }

    private func cancelLiveTranscriptionSession() async {
        stopStreamHeartbeat()
        if let session = liveTranscriptionSession {
            await session.cancel()
        }
        liveTranscriptionSession = nil
        streamConnectionPhase = .disconnected
        clearStreamCaptions()
        audioLevel = 0
    }

    private func startStreamHeartbeat() {
        stopStreamHeartbeat()
        streamHeartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(RealtimeTranscriptionConfig.heartbeatIntervalSeconds))
                guard !Task.isCancelled, let self else { return }
                await self.liveTranscriptionSession?.heartbeat()
                if let session = self.liveTranscriptionSession {
                    let phase = await session.connectionPhase
                    await MainActor.run {
                        self.streamConnectionPhase = phase
                    }
                }
            }
        }
    }

    private func stopStreamHeartbeat() {
        streamHeartbeatTask?.cancel()
        streamHeartbeatTask = nil
    }

    private func throttledStreamClipboardWrite(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 3 else { return }

        let hash = trimmed.hashValue
        let now = Date()
        if hash == lastStreamClipboardHash,
           let lastStreamClipboardUpdate,
           now.timeIntervalSince(lastStreamClipboardUpdate) < 1 {
            return
        }

        lastStreamClipboardHash = hash
        lastStreamClipboardUpdate = now
        do {
            try clipboardWriter.write(trimmed)
            lastClipboardStatusKey = "record.clipboard.copied"
        } catch {
            lastClipboardStatusKey = "record.clipboard.failed"
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
        if let streamError = error as? RealtimeTranscriptionError {
            switch streamError {
            case .invalidBaseURL, .missingToken, .connectionLost, .sessionUnavailable, .httpError:
                return "transcription_upload_failed"
            case .invalidMessage, .websocketError, .emptyTranscript, .audioConversionFailed:
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
