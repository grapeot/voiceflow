import Combine
import Foundation
import SwiftUI
import VoiceFlowKit

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
    @Published private(set) var streamConnectionPhase: VoiceFlowConnectionPhase = .disconnected
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
    /// Free-form context prompt passed to the transcription model.
    /// Helps with proper nouns, jargon, code-switching, and language
    /// hints (the user can write e.g. "Speaker is using Mandarin
    /// Chinese" if they want to nudge language detection). Persisted
    /// in UserDefaults so it survives relaunch.
    @Published var transcriptionPrompt: String {
        didSet { UserDefaults.standard.set(transcriptionPrompt, forKey: Self.transcriptionPromptDefaultsKey) }
    }
    /// Comma-separated list of domain-specific terms the recognizer should
    /// preserve verbatim. Stored as a single string in the UI to keep the
    /// editing UX simple; parsed into [String] when handed to the kit.
    @Published var transcriptionTerms: String {
        didSet { UserDefaults.standard.set(transcriptionTerms, forKey: Self.transcriptionTermsDefaultsKey) }
    }

    let aiBuilderEndpoint = "https://space.ai-builders.com/backend"
    let keychainStore: KeychainStoring
    let aiBuilderClient: AIBuilderConnectionTesting
    let audioRecorder: AudioRecording
    let transcriptionClient: AIBuilderTranscribing
    let voiceFlowClient: VoiceFlowClient
    let clipboardWriter: ClipboardWriting
    let openCodeClient: OpenCodeSending
    let diagnostics: RecordingDiagnosticsReporting
    let tokenKey = "aiBuilderToken"
    let openCodePasswordKey = "openCodePassword"
    private static let openCodeServerURLDefaultsKey = "openCodeServerURL"
    private static let openCodeUsernameDefaultsKey = "openCodeUsername"
    private static let appLanguageDefaultsKey = "appLanguage"
    private static let transcriptionPromptDefaultsKey = "transcriptionPrompt"
    private static let transcriptionTermsDefaultsKey = "transcriptionTerms"
    private static let streamHeartbeatIntervalSeconds: UInt64 = 12
    private var lastRecordingURL: URL?
    private var recordingTimerStartDate: Date?
    private var recordingTimer: Timer?
    private var liveTranscriptionSession: VoiceFlowSession?
    private var liveEventConsumerTask: Task<Void, Never>?
    private var streamHeartbeatTask: Task<Void, Never>?
    private var lastStreamClipboardHash: Int?
    private var lastStreamClipboardUpdate: Date?
    private var userEditedTranscriptDuringStream = false
    private var isTranscriptionTeardown = false

    private static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// Default stub VoiceFlowClient for UI test mode and unit-test target
    /// auto-discovery. Tests that need behavior beyond the canned stub
    /// (custom mock state, error injection, event scripting) construct
    /// their own via `@testable import VoiceFlowKit` and pass it through
    /// the `voiceFlowClient:` DI parameter.
    private static func makeMockVoiceFlowClient() -> VoiceFlowClient {
        VoiceFlowClient.makeStub(liveTranscript: "Mock transcription")
    }

    init(
        keychainStore: KeychainStoring? = nil,
        aiBuilderClient: AIBuilderConnectionTesting? = nil,
        audioRecorder: AudioRecording? = nil,
        transcriptionClient: AIBuilderTranscribing? = nil,
        voiceFlowClient: VoiceFlowClient? = nil,
        clipboardWriter: ClipboardWriting? = nil,
        openCodeClient: OpenCodeSending? = nil,
        diagnostics: RecordingDiagnosticsReporting? = nil
    ) {
        let isUITestMode = ProcessInfo.processInfo.arguments.contains("-uiTestMode")
        if isUITestMode, ProcessInfo.processInfo.arguments.contains("-uiTestResetPreferences") {
            UserDefaults.standard.removeObject(forKey: Self.openCodeServerURLDefaultsKey)
            UserDefaults.standard.removeObject(forKey: Self.openCodeUsernameDefaultsKey)
            UserDefaults.standard.removeObject(forKey: Self.appLanguageDefaultsKey)
            UserDefaults.standard.removeObject(forKey: Self.transcriptionPromptDefaultsKey)
            UserDefaults.standard.removeObject(forKey: Self.transcriptionTermsDefaultsKey)
        }
        self.openCodeServerURL = UserDefaults.standard.string(forKey: Self.openCodeServerURLDefaultsKey) ?? OpenCodeClient.defaultServerURL
        self.openCodeUsername = UserDefaults.standard.string(forKey: Self.openCodeUsernameDefaultsKey) ?? OpenCodeClient.defaultUsername
        let savedLanguage = UserDefaults.standard.string(forKey: Self.appLanguageDefaultsKey).flatMap(AppLanguage.init(rawValue:))
        self.appLanguage = savedLanguage ?? .system
        self.transcriptionPrompt = UserDefaults.standard.string(forKey: Self.transcriptionPromptDefaultsKey) ?? ""
        self.transcriptionTerms = UserDefaults.standard.string(forKey: Self.transcriptionTermsDefaultsKey) ?? ""
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
        if let voiceFlowClient {
            self.voiceFlowClient = voiceFlowClient
        } else if isUITestMode || Self.isRunningUnitTests {
            self.voiceFlowClient = AppState.makeMockVoiceFlowClient()
        } else {
            let keychain = self.keychainStore
            let tokenLookupKey = self.tokenKey
            let config = VoiceFlowConfig(
                endpoint: URL(string: aiBuilderEndpoint)!,
                tokenProvider: {
                    let stored = try? keychain.readString(for: tokenLookupKey)
                    return stored ?? ""
                }
            )
            self.voiceFlowClient = VoiceFlowClient(config: config)
        }
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

        UserDefaults.standard.removeObject(forKey: Self.openCodeServerURLDefaultsKey)
        UserDefaults.standard.removeObject(forKey: Self.openCodeUsernameDefaultsKey)
        UserDefaults.standard.removeObject(forKey: Self.appLanguageDefaultsKey)
        UserDefaults.standard.removeObject(forKey: Self.transcriptionPromptDefaultsKey)
        UserDefaults.standard.removeObject(forKey: Self.transcriptionTermsDefaultsKey)
        openCodeServerURL = OpenCodeClient.defaultServerURL
        openCodeUsername = OpenCodeClient.defaultUsername
        appLanguage = .system
        transcriptionPrompt = ""
        transcriptionTerms = ""

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
            streamConnectionPhase = .connecting
            recordDiagnostic("recording_start_requested", metadata: ["hasToken": "true", "mode": "stream"])

            await applyCurrentTranscriptionConfig(token: token)
            let session = try await voiceFlowClient.startSession()
            liveTranscriptionSession = session
            startLiveEventConsumer(for: session)
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

        await finishLiveTranscriptionSession()
    }

    func handleScenePhaseChange(to phase: ScenePhase) async {
        switch phase {
        case .active:
            await liveTranscriptionSession?.ping()
        case .background:
            stopStreamHeartbeat()
            await liveTranscriptionSession?.cancel()
            liveEventConsumerTask?.cancel()
            liveEventConsumerTask = nil
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

    func recordDiagnostic(_ name: String, metadata: [String: String] = [:]) {
        diagnostics.record(RecordingDiagnosticEvent(name, metadata: metadata))
    }

    /// Refresh the kit-side config with the current token + prompt + terms
    /// from Settings. `tokenProvider` is rebuilt to close over the token
    /// value (rather than re-reading Keychain on every call) so the
    /// session sees a consistent token even if the user clears it
    /// mid-session.
    private func applyCurrentTranscriptionConfig(token: String) async {
        let trimmedPrompt = transcriptionPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedTerms = transcriptionTerms
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let endpoint = URL(string: aiBuilderEndpoint)!
        let config = VoiceFlowConfig(
            endpoint: endpoint,
            tokenProvider: { token },
            prompt: trimmedPrompt.isEmpty ? nil : trimmedPrompt,
            terms: parsedTerms
        )
        await voiceFlowClient.updateConfig(config)
    }

    /// Drain the session's event stream onto the main actor. The stream
    /// is cold; iteration starts here and runs until the session is
    /// torn down (commit / cancel / error). Cancelling
    /// `liveEventConsumerTask` is how we unsubscribe.
    private func startLiveEventConsumer(for session: VoiceFlowSession) {
        liveEventConsumerTask?.cancel()
        liveEventConsumerTask = Task { [weak self] in
            let events = await session.events
            for await event in events {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.handleStreamEvent(event)
                }
            }
        }
    }

    func diagnosticMetadata(for error: Error) -> [String: String] {
        DiagnosticErrorMetadata.metadata(for: error)
    }

    func userFacingErrorDetail(for error: Error) -> String {
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
            await applyCurrentTranscriptionConfig(token: token)
            let result = try await voiceFlowClient.transcribe(audioFile: audioURL) { [weak self] partial in
                Task { @MainActor in
                    self?.transcript = partial
                }
            }
            let transcribedText = result.text
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

    private func handleStreamEvent(_ event: VoiceFlowEvent) {
        switch event {
        case .partialTranscript(let content):
            guard recordingStatus != .recording else { return }
            if !userEditedTranscriptDuringStream {
                transcript = content
                throttledStreamClipboardWrite(transcript)
            }
        case .phaseChanged(let phase):
            streamConnectionPhase = phase
            switch phase {
            case .connected, .connecting:
                if recordingStatus == .recording,
                   persistentStreamCaptionKey == "record.status.reconnecting" {
                    setPersistentStreamCaption(nil)
                    flashTransientStreamCaption("record.status.reconnected")
                }
            case .recovering:
                if recordingStatus == .recording {
                    setPersistentStreamCaption("record.status.reconnecting")
                }
            case .disconnected, .generating:
                break
            }
        case .recoveryStarted:
            streamConnectionPhase = .recovering
            if recordingStatus == .recording {
                setPersistentStreamCaption("record.status.reconnecting")
            }
        case .recoveryFailed(let message):
            if isTranscriptionTeardown {
                return
            }
            recordDiagnostic("transcription_stream_recovery_failed", metadata: ["reason": message])
            streamConnectionPhase = .disconnected
            if recordingStatus == .recording {
                setPersistentStreamCaption("record.error.streamDisconnected")
            } else if recordingStatus == .transcribing {
                setPersistentStreamCaption("record.error.streamDisconnected")
            } else if !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                setPersistentStreamCaption("record.error.streamDisconnected")
            } else {
                presentRecordError("record.error.transcriptionFailed")
            }
        }
    }

    private func handleCapturedPCMChunk(_ chunk: Data) async {
        updateAudioLevel(from: chunk)
        await liveTranscriptionSession?.sendAudioChunk(chunk)
    }

    /// Compute RMS of a PCM16 little-endian chunk via VoiceFlowKit's metering
    /// helper, then feed it into an exponential moving average so the waveform
    /// never jitters on short silences mid-syllable. 30 % new sample,
    /// 70 % carried — short attack, slow release.
    private func updateAudioLevel(from chunk: Data) {
        let normalized = VoiceFlowAudioMetering.normalizedLevel(fromPCM16LE: chunk)
        audioLevel = audioLevel * 0.7 + normalized * 0.3
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
            streamText = try await session.commitAndStop(onPartialTranscript: makeFinalizePartialHandler())
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
        liveEventConsumerTask?.cancel()
        liveEventConsumerTask = nil
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
                try? await Task.sleep(for: .seconds(Self.streamHeartbeatIntervalSeconds))
                guard !Task.isCancelled, let self else { return }
                await self.liveTranscriptionSession?.ping()
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
        if let kitError = error as? VoiceFlowError {
            switch kitError {
            case .invalidEndpoint, .missingToken, .connectionLost, .sessionUnavailable, .httpError:
                return "transcription_upload_failed"
            case .websocketError, .emptyTranscript, .audioConversionFailed, .microphoneUnavailable, .underlying:
                return "transcription_response_failed"
            }
        }
        if error is DecodingError {
            return "transcription_response_failed"
        }
        return "transcription_upload_failed"
    }

}
