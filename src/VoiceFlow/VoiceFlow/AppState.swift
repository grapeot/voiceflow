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
                UserDefaults.standard.set(false, forKey: Self.openCodeConnectionVerifiedDefaultsKey)
                openCodeConnectionStatus = .untested
            }
        }
    }
    @Published var openCodeUsername: String {
        didSet {
            UserDefaults.standard.set(openCodeUsername, forKey: Self.openCodeUsernameDefaultsKey)
            if oldValue != openCodeUsername {
                UserDefaults.standard.set(false, forKey: Self.openCodeConnectionVerifiedDefaultsKey)
                openCodeConnectionStatus = .untested
            }
        }
    }
    @Published var hasSavedOpenCodePassword = false
    @Published var openCodeSendStatus: OpenCodeSendStatus = .idle
    @Published var openCodeConnectionStatus: ConnectionStatus = .untested
    @Published var lastClipboardStatusKey: String?
    @Published internal(set) var lastSavedRecording: SavedRecordingInfo?
    @Published var shouldPresentSavedRecordingAlert = false
    @Published var connectionStatus: ConnectionStatus = .untested
    @Published internal(set) var streamConnectionPhase: VoiceFlowConnectionPhase = .disconnected
    /// Long-lived status the user should keep seeing — currently
    /// "Reconnecting…" while the stream is auto-recovering and
    /// "Stream disconnected." after recovery fails. Set this directly only
    /// for states that genuinely persist; transient confirmations like
    /// "Stream restored." go through `flashTransientStreamCaption(_:)`.
    @Published internal(set) var persistentStreamCaptionKey: String?
    /// Briefly overlaid on top of `persistentStreamCaptionKey`. Currently
    /// used for "Stream restored.": we want to acknowledge the recovery but
    /// not leave that confirmation on screen indefinitely. After
    /// `transientStreamCaptionDuration` seconds it clears itself, revealing
    /// whatever `persistentStreamCaptionKey` currently is (which, by then,
    /// is usually nil — i.e. silent normal operation).
    @Published internal(set) var transientStreamCaptionKey: String?
    /// What RecordView reads. Transient layer wins so a flash confirmation
    /// hides the underlying state; once the flash clears, the persistent
    /// layer (which may itself be nil) shows through.
    var streamStatusCaptionKey: String? {
        transientStreamCaptionKey ?? persistentStreamCaptionKey
    }
    var transientStreamCaptionTask: Task<Void, Never>?
    let transientStreamCaptionDuration: Duration = .seconds(3)
    @Published internal(set) var recordingTimerText = "00:00"
    /// Smoothed 0…1 microphone level. Driven by the mic PCM tap while
    /// recording; falls back to 0 when idle/transcribing/error so the
    /// waveform reads as quiet rather than frozen.
    @Published internal(set) var audioLevel: Float = 0

    // MARK: - Signal quality detection

    /// Raw RMS peak across the entire recording (0..1, untransformed).
    /// Used to detect Tier 1 (zero signal) at Stop time.
    @Published internal(set) var peakRms: Float = 0
    /// Accumulated milliseconds of audio where RMS exceeded the speech
    /// threshold. Used to distinguish Tier 2 (short) from Tier 3 (normal).
    @Published internal(set) var activeAudioMs: Double = 0
    /// Result of signal quality evaluation at Stop time. Nil while recording
    /// or before first evaluation. Drives Tier 1 alert and Tier 2 warning.
    @Published internal(set) var signalTier: SignalTier?

    enum SignalTier: Equatable {
        case tier1NoSignal
        case tier2ShortAudio
        case tier3Normal
    }

    internal var signalBannerGraceTask: Task<Void, Never>?

    static let silenceFloor: Float = 0.002
    static let speechThreshold: Float = 0.003
    static let activeAudioShortMs: Double = 1500
    static let signalBannerGraceMs: Int = 300

    /// True when the last recording was Tier 2 (short audio) and the
    /// transcript warning should be shown above the transcript text.
    /// Cleared on next recording start.
    var showTranscriptWarning: Bool {
        signalTier == .tier2ShortAudio && recordingStatus == .ready
    }

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
    static let tokenKey = "aiBuilderToken"               // Keychain
    static let openCodePasswordKey = "openCodePassword"  // Keychain
    static let openCodeServerURLDefaultsKey = "openCodeServerURL"      // UserDefaults
    static let openCodeUsernameDefaultsKey = "openCodeUsername"        // UserDefaults
    static let openCodeConnectionVerifiedDefaultsKey = "openCodeConnectionVerified"  // UserDefaults
    static let appLanguageDefaultsKey = "appLanguage"                  // UserDefaults
    static let transcriptionPromptDefaultsKey = "transcriptionPrompt"  // UserDefaults
    static let transcriptionTermsDefaultsKey = "transcriptionTerms"    // UserDefaults
    static let streamHeartbeatIntervalSeconds: UInt64 = 12
    var lastRecordingURL: URL?
    var recordingTimerStartDate: Date?
    var recordingTimer: Timer?
    var liveTranscriptionSession: VoiceFlowSession?
    var liveEventConsumerTask: Task<Void, Never>?
    var streamHeartbeatTask: Task<Void, Never>?
    var userEditedTranscriptDuringStream = false
    var isTranscriptionTeardown = false

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
            UserDefaults.standard.removeObject(forKey: Self.openCodeConnectionVerifiedDefaultsKey)
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
            let tokenLookupKey = Self.tokenKey
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
        self.hasSavedAIBuilderToken = (try? self.keychainStore.readString(for: Self.tokenKey)) != nil
        self.hasSavedOpenCodePassword = (try? self.keychainStore.readString(for: Self.openCodePasswordKey)) != nil
        if self.hasSavedOpenCodePassword,
           !self.openCodeServerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !self.openCodeUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           UserDefaults.standard.bool(forKey: Self.openCodeConnectionVerifiedDefaultsKey) {
            self.openCodeConnectionStatus = .success
        }
        if isUITestMode, ProcessInfo.processInfo.arguments.contains("-uiTestDeepLinkRecord") {
            handleIncomingURL(URL(string: "voiceflow://record")!)
        }
        consumePendingStartRecordingIntentRequest()
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

    func consumePendingStartRecordingIntentRequest() {
        guard StartRecordingIntentRequest.consumePending() else { return }
        recordDiagnostic("app_intent_start_recording_received")
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
        isTranscriptionTeardown = false
        selectedTab = .record

        UserDefaults.standard.removeObject(forKey: Self.openCodeServerURLDefaultsKey)
        UserDefaults.standard.removeObject(forKey: Self.openCodeUsernameDefaultsKey)
        UserDefaults.standard.removeObject(forKey: Self.openCodeConnectionVerifiedDefaultsKey)
        UserDefaults.standard.removeObject(forKey: Self.appLanguageDefaultsKey)
        UserDefaults.standard.removeObject(forKey: Self.transcriptionPromptDefaultsKey)
        UserDefaults.standard.removeObject(forKey: Self.transcriptionTermsDefaultsKey)
        openCodeServerURL = OpenCodeClient.defaultServerURL
        openCodeUsername = OpenCodeClient.defaultUsername
        appLanguage = .system
        transcriptionPrompt = ""
        transcriptionTerms = ""

        try? keychainStore.deleteString(for: Self.tokenKey)
        try? keychainStore.deleteString(for: Self.openCodePasswordKey)
        hasSavedAIBuilderToken = false
        hasSavedOpenCodePassword = false

        applyUITestLaunchArgumentSeeds()
    }

    private func applyUITestLaunchArgumentSeeds() {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-uiTestSavedToken") {
            try? keychainStore.saveString("fake-ui-token", for: Self.tokenKey)
            hasSavedAIBuilderToken = true
        }
        if arguments.contains("-uiTestSavedOpenCode") {
            openCodeServerURL = OpenCodeClient.defaultServerURL
            openCodeUsername = OpenCodeClient.defaultUsername
            try? keychainStore.saveString("fake-opencode-password", for: Self.openCodePasswordKey)
            hasSavedOpenCodePassword = true
            UserDefaults.standard.set(true, forKey: Self.openCodeConnectionVerifiedDefaultsKey)
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

    // Rescue affordance: saving the already-recorded audio must stay available
    // whenever an audio file exists, including while transcription is stuck in
    // `.transcribing`. We deliberately do NOT gate this on
    // `canNavigateTranscriptHistory` (which is false during `.transcribing`),
    // because that would lock the user out of recovering their audio exactly
    // when the live session hangs.
    var canSaveRecording: Bool {
        lastRecordingFileExists
    }

    // Replay = close the current (possibly hung) WebSocket session and re-run
    // transcription from the saved audio. It must be available in the stuck
    // `.transcribing` case, so it is also no longer gated on
    // `canNavigateTranscriptHistory`.
    var canResendRecording: Bool {
        hasSavedAIBuilderToken
            && (recordingStatus == .recording || lastRecordingFileExists)
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

        guard let token = try? keychainStore.readString(for: Self.tokenKey), !token.isEmpty else {
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
            peakRms = 0
            activeAudioMs = 0
            signalTier = nil
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
            startSignalBannerGraceTimer()
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
        cancelSignalBannerGraceTimer()
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

        // Signal quality gate: evaluate before committing.
        let tier = evaluateSignalTier()
        signalTier = tier
        recordDiagnostic("signal_tier_evaluated", metadata: [
            "tier": "\(tier)",
            "peakRms": "\(peakRms)",
            "activeAudioMs": "\(activeAudioMs)"
        ])

        if tier == .tier1NoSignal {
            // Don't commit — OpenAI would hallucinate on empty audio.
            try? FileManager.default.removeItem(at: audioURL)
            await cancelLiveTranscriptionSession()
            clearStreamCaptions()
            resetRecordingTimer()
            recordingStatus = .idle
            audioLevel = 0
            presentRecordError("record.signal.noSignal")
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

    func resendLastRecording() async {
        guard canResendRecording else { return }
        let shouldStopActiveRecording = recordingStatus == .recording
        recordingStatus = .transcribing
        openCodeSendStatus = .idle
        lastClipboardStatusKey = nil
        recordDiagnostic("recording_resend_requested")

        if shouldStopActiveRecording {
            let audioURL: URL
            do {
                stopRecordingTimer()
                audioURL = try await audioRecorder.stopRecording()
            } catch {
                await cancelLiveTranscriptionSession()
                recordDiagnostic("recording_resend_stop_failed", metadata: diagnosticMetadata(for: error))
                presentRecordError("record.error.transcriptionFailed")
                return
            }

            let audioMetadata = audioFileMetadata(for: audioURL)
            if audioMetadata["byteCount"] == "0" {
                try? FileManager.default.removeItem(at: audioURL)
                await cancelLiveTranscriptionSession()
                recordDiagnostic("recording_resend_audio_file_empty")
                presentRecordError("record.error.transcriptionFailed")
                return
            }

            do {
                lastRecordingURL = try persistLastRecording(from: audioURL)
            } catch {
                try? FileManager.default.removeItem(at: audioURL)
                await cancelLiveTranscriptionSession()
                recordDiagnostic("recording_resend_persist_failed", metadata: diagnosticMetadata(for: error))
                presentRecordError("record.error.transcriptionFailed")
                return
            }
            try? FileManager.default.removeItem(at: audioURL)
            await cancelLiveTranscriptionSession()
        } else {
            // Rescue path: transcription is stuck (e.g. a hung live WebSocket
            // session that never returned). Force-close any active session so we
            // start the re-transcription from a clean state instead of layering
            // on top of the stalled one.
            await cancelLiveTranscriptionSession()
        }

        if let bulkText = await finishTranscriptionFromLastRecording(presentErrorOnFailure: true) {
            transcript = bulkText
            transcriptHistory.add(bulkText)
            copyTranscript()
            recordingStatus = .ready
        }
    }

    func presentRecordError(_ key: String) {
        recordErrorAlertKey = key
        recordingStatus = .idle
        stopRecordingTimer()
    }

}
