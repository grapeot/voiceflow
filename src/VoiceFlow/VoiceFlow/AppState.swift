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
    @Published var transcript: String = "" {
        didSet {
            // Any write that is not immediately followed by a merge updating
            // `lastChunkLength` (user edits, navigation, custom action
            // results, clears) means the tracked last-chunk boundary no
            // longer matches the displayed text. Resends then fall back to
            // end-append instead of replacing a chunk they cannot locate.
            lastChunkLength = nil
        }
    }
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
    static let speechThreshold: Float = 0.008
    static let activeAudioShortMs: Double = 1500
    static let signalBannerGraceMs: Int = 300

    /// True when the last recording was Tier 2 (short audio) and the
    /// transcript warning should be shown above the transcript text.
    /// Cleared on next recording start.
    var showTranscriptWarning: Bool {
        signalTier == .tier2ShortAudio && recordingStatus == .ready
    }

    var hasActiveWaveformFeedback: Bool {
        guard recordingStatus == .recording else { return false }
        if !activeRecordingStrategy.usesRealtimeTransport { return true }
        return streamConnectionPhase == .connected || streamConnectionPhase == .generating
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
    @Published var transcriptionStrategy: VoiceFlowRecordingStrategy {
        didSet { UserDefaults.standard.set(transcriptionStrategy.rawValue, forKey: Self.transcriptionStrategyDefaultsKey) }
    }
    /// How finished transcriptions combine with existing text. Session
    /// scoped: in-memory only, defaults back to `.replace` on relaunch.
    /// Toggled from the Record screen ⋯ menu, not Settings.
    @Published var transcriptMode: TranscriptMode = .replace

    // MARK: - In-flight transcription chunk (two-layer transcript model)

    /// The frozen base the in-flight chunk composes onto. Empty for the
    /// replace mode and for append recordings that start from an empty
    /// transcript; otherwise the document (new recording) or the document
    /// minus its last chunk (resend).
    internal var composeBase: String = ""
    /// True while a transcription chunk (live or finalize) is being built.
    internal var chunkInFlight: Bool = false
    /// Character count of the last merged chunk, so a resend can replace
    /// exactly that tail instead of appending a duplicate. Invalidated by
    /// any transcript write that is not a merge (see `transcript.didSet`).
    internal var lastChunkLength: Int?
    /// Append mode: the transcript as displayed when a resend started.
    /// Restored if the re-transcription fails so the pre-resend document
    /// (including its old last chunk) is never lost to a partial re-write.
    internal var preResendDocument: String?
    /// Append mode: `lastChunkLength` as of the resend start. Restoring the
    /// pre-resend document would otherwise invalidate the chunk boundary
    /// (via `transcript.didSet`) and the next resend would append a
    /// duplicate tail instead of replacing it.
    internal var preResendChunkLength: Int?
    /// True once the in-flight chunk's audio has been persisted and is the
    /// resend target (`lastRecordingURL`). A failure settle may only write
    /// a chunk boundary for the resendable audio: while this is false the
    /// displayed partial belongs to a recording that never became resendable
    /// (stop/signal/persist failed), and a later resend must not cut it out
    /// of the document.
    internal var chunkAudioIsResendTarget: Bool = false
    /// The mode captured when the current recording started. The ⋯ menu
    /// is locked during recording, so this equals `transcriptMode` for the
    /// whole recording; resends re-capture it at resend start.
    internal var activeTranscriptMode: TranscriptMode = .replace
    /// Monotonic identity of the live event consumer. Events that reach the
    /// main actor from a superseded (cancelled) session carry an older
    /// generation and are dropped, preventing stale snapshots from
    /// composing onto a newer recording's chunk.
    internal var liveSessionGeneration: Int = 0

    // MARK: - Local ASR (on-device Qwen3-ASR)

    /// Download/readiness state of the on-device model weights. Surfaced in
    /// Settings and gated before Start when the Local strategy is selected.
    /// Written by the download flow in `AppState+LiveSession` and UI-test
    /// resets; treat the setter as framework-internal.
    @Published var localModelStatus: LocalAsrModelStatus = .notDownloaded
    var localModelDownloadTask: Task<Void, Never>?
    var localModelLastProgressAt: Date?
    /// Whether this device/OS can run the on-device engine at all (iOS 18+).
    var isLocalAsrSupported: Bool { localAsrEngine.isSupportedOnThisDevice }
    var canResumeLocalModelDownload: Bool { localAsrEngine.hasResumableDownload() }
    var isLocalModelDownloadStalled: Bool {
        guard localModelStatus.isInFlight, localModelDownloadTask != nil else { return false }
        guard let last = localModelLastProgressAt else { return false }
        return Date().timeIntervalSince(last) > 20
    }

    // MARK: - Custom Action

    /// User-defined text transformation config (action name + instructions).
    /// Persisted in UserDefaults; the AI Builder token stays in Keychain.
    @Published var customActionConfig: CustomActionConfig {
        didSet {
            UserDefaults.standard.set(
                (try? JSONEncoder().encode(customActionConfig)) ?? Data(),
                forKey: Self.customActionConfigDefaultsKey
            )
        }
    }
    /// Live state of the custom action request. Independent from recording
    /// state so a transform cannot race with a new recording or Resend.
    @Published internal(set) var customActionState: CustomActionState = .idle
    /// Snapshot of the source transcript captured at request start. Used so
    /// a late response cannot overwrite text the user changed after tapping.
    internal var customActionSourceSnapshot: String?
    internal var customActionTask: Task<Void, Never>?

    let customActionClient: CustomActionSending

    let aiBuilderEndpoint = "https://space.ai-builders.com/backend"
    let keychainStore: KeychainStoring
    let aiBuilderClient: AIBuilderConnectionTesting
    let audioRecorder: AudioRecording
    let transcriptionClient: AIBuilderTranscribing
    let voiceFlowClient: VoiceFlowClient
    let clipboardWriter: ClipboardWriting
    let openCodeClient: OpenCodeSending
    let localAsrEngine: LocalAsrTranscribing
    let diagnostics: RecordingDiagnosticsReporting
    let screenIdleController: ScreenIdleControlling
    static let tokenKey = "aiBuilderToken"               // Keychain
    static let openCodePasswordKey = "openCodePassword"  // Keychain
    static let openCodeServerURLDefaultsKey = "openCodeServerURL"      // UserDefaults
    static let openCodeUsernameDefaultsKey = "openCodeUsername"        // UserDefaults
    static let openCodeConnectionVerifiedDefaultsKey = "openCodeConnectionVerified"  // UserDefaults
    static let appLanguageDefaultsKey = "appLanguage"                  // UserDefaults
    static let transcriptionPromptDefaultsKey = "transcriptionPrompt"  // UserDefaults
    static let transcriptionTermsDefaultsKey = "transcriptionTerms"    // UserDefaults
    static let transcriptionStrategyDefaultsKey = "transcriptionStrategy"  // UserDefaults
    static let customActionConfigDefaultsKey = "customActionConfig"  // UserDefaults
    static let streamHeartbeatIntervalSeconds: UInt64 = 12
    var lastRecordingURL: URL?
    var recordingTimerStartDate: Date?
    var recordingTimer: Timer?
    var liveTranscriptionSession: VoiceFlowSession?
    var liveEventConsumerTask: Task<Void, Never>?
    var streamHeartbeatTask: Task<Void, Never>?
    var capturedPCMBuffer: OrderedPCMChunkBuffer?
    var capturedPCMConsumerTask: Task<Void, Never>?
    var activeTranscriptionAttemptID: UUID?
    var partialTranscriptAttemptID: UUID?
    var userEditedTranscriptDuringStream = false
    var isTranscriptionTeardown = false
    var activeRecordingStrategy: VoiceFlowRecordingStrategy = .gptLiveTranscribe
    var lastRecordingStrategy: VoiceFlowRecordingStrategy = .gptLiveTranscribe

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

    private static func loadCustomActionConfig() -> CustomActionConfig {
        guard let data = UserDefaults.standard.data(forKey: customActionConfigDefaultsKey),
              let decoded = try? JSONDecoder().decode(CustomActionConfig.self, from: data)
        else {
            // No saved config: use a localized default based on the current
            // app language so first-run users see their language's name and
            // instructions. Once the user edits and persists, their choice
            // sticks regardless of later language changes.
            let savedLanguage = UserDefaults.standard.string(forKey: appLanguageDefaultsKey).flatMap(AppLanguage.init(rawValue:)) ?? .system
            return CustomActionConfig.localizedDefault(for: savedLanguage)
        }
        return decoded
    }

    init(
        keychainStore: KeychainStoring? = nil,
        aiBuilderClient: AIBuilderConnectionTesting? = nil,
        audioRecorder: AudioRecording? = nil,
        transcriptionClient: AIBuilderTranscribing? = nil,
        voiceFlowClient: VoiceFlowClient? = nil,
        clipboardWriter: ClipboardWriting? = nil,
        openCodeClient: OpenCodeSending? = nil,
        localAsrEngine: LocalAsrTranscribing? = nil,
        diagnostics: RecordingDiagnosticsReporting? = nil,
        customActionClient: CustomActionSending? = nil,
        screenIdleController: ScreenIdleControlling? = nil
    ) {
        let isUITestMode = ProcessInfo.processInfo.arguments.contains("-uiTestMode")
        if isUITestMode, ProcessInfo.processInfo.arguments.contains("-uiTestResetPreferences") {
            UserDefaults.standard.removeObject(forKey: Self.openCodeServerURLDefaultsKey)
            UserDefaults.standard.removeObject(forKey: Self.openCodeUsernameDefaultsKey)
            UserDefaults.standard.removeObject(forKey: Self.openCodeConnectionVerifiedDefaultsKey)
            UserDefaults.standard.removeObject(forKey: Self.appLanguageDefaultsKey)
            UserDefaults.standard.removeObject(forKey: Self.transcriptionPromptDefaultsKey)
            UserDefaults.standard.removeObject(forKey: Self.transcriptionTermsDefaultsKey)
            UserDefaults.standard.removeObject(forKey: Self.transcriptionStrategyDefaultsKey)
            UserDefaults.standard.removeObject(forKey: Self.customActionConfigDefaultsKey)
        }
        self.openCodeServerURL = UserDefaults.standard.string(forKey: Self.openCodeServerURLDefaultsKey) ?? OpenCodeClient.defaultServerURL
        self.openCodeUsername = UserDefaults.standard.string(forKey: Self.openCodeUsernameDefaultsKey) ?? OpenCodeClient.defaultUsername
        let savedLanguage = UserDefaults.standard.string(forKey: Self.appLanguageDefaultsKey).flatMap(AppLanguage.init(rawValue:))
        self.appLanguage = savedLanguage ?? .system
        self.transcriptionPrompt = UserDefaults.standard.string(forKey: Self.transcriptionPromptDefaultsKey) ?? ""
        self.transcriptionTerms = UserDefaults.standard.string(forKey: Self.transcriptionTermsDefaultsKey) ?? ""
        self.transcriptionStrategy = UserDefaults.standard.string(forKey: Self.transcriptionStrategyDefaultsKey)
            .flatMap(VoiceFlowRecordingStrategy.init(rawValue:)) ?? .gptLiveTranscribe
        self.customActionConfig = Self.loadCustomActionConfig()
        self.customActionClient = customActionClient ?? (isUITestMode ? MockCustomActionClient(result: .success("Mock polish result")) : CustomActionClient())
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
        self.localAsrEngine = localAsrEngine ?? (isUITestMode || Self.isRunningUnitTests ? MockLocalAsrEngine() : FluidAudioLocalAsrEngine())
        if self.localAsrEngine.isSupportedOnThisDevice, self.localAsrEngine.isModelReady() {
            self.localModelStatus = .ready
        }
        self.diagnostics = diagnostics ?? (isUITestMode ? InMemoryRecordingDiagnostics() : OSRecordingDiagnostics())
        self.screenIdleController = screenIdleController ?? SystemScreenIdleController()
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

        invalidateTranscriptionAttempt()
        await cancelCapturedPCMConsumer()
        await cancelLiveTranscriptionSession()
        stopRecordingTimer()
        setScreenIdleTimer(disabled: false)
        localModelDownloadTask?.cancel()
        localModelDownloadTask = nil
        localModelStatus = .notDownloaded
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
        UserDefaults.standard.removeObject(forKey: Self.transcriptionStrategyDefaultsKey)
        UserDefaults.standard.removeObject(forKey: Self.customActionConfigDefaultsKey)
        openCodeServerURL = OpenCodeClient.defaultServerURL
        openCodeUsername = OpenCodeClient.defaultUsername
        appLanguage = .system
        transcriptionPrompt = ""
        transcriptionTerms = ""
        transcriptionStrategy = .gptLiveTranscribe
        transcriptMode = .replace
        activeTranscriptMode = .replace
        composeBase = ""
        chunkInFlight = false
        chunkAudioIsResendTarget = false
        lastChunkLength = nil
        preResendDocument = nil
        preResendChunkLength = nil
        customActionConfig = .default
        customActionState = .idle
        customActionSourceSnapshot = nil
        customActionTask?.cancel()
        customActionTask = nil
        activeRecordingStrategy = .gptLiveTranscribe
        lastRecordingStrategy = .gptLiveTranscribe

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
        if arguments.contains("-uiTestTranscriptModeAppend") {
            transcriptMode = .append
            activeTranscriptMode = .append
        }
    }

    var canCopyTranscript: Bool {
        !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canStartRecording: Bool {
        (recordingStatus == .idle || recordingStatus == .ready)
            && !customActionState.isRunning
    }

    var canStopRecording: Bool {
        recordingStatus == .recording
    }

    var canNavigateTranscriptHistory: Bool {
        (recordingStatus == .idle || recordingStatus == .ready)
            && !customActionState.isRunning
    }

    /// Left chevron is also the undo for a cleared view: when the
    /// transcript is empty but history holds entries, the previous step
    /// restores the entry the view is currently at instead of stepping
    /// further back.
    var canNavigatePreviousTranscript: Bool {
        guard canNavigateTranscriptHistory else { return false }
        if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return !transcriptHistory.isEmpty
        }
        return transcriptHistory.hasPrevious
    }

    var canNavigateNextTranscript: Bool {
        canNavigateTranscriptHistory && transcriptHistory.hasNext
    }

    /// Mode switching is allowed outside of a recording (the mode is
    /// captured when a recording starts) and while the custom action is
    /// not running.
    var canChangeTranscriptMode: Bool {
        (recordingStatus == .idle || recordingStatus == .ready)
            && !customActionState.isRunning
    }

    /// Trash button: archive the current transcript to history and clear
    /// the transcript area. Available in both modes, only when the view
    /// is settled (nothing in flight) and there is something to archive.
    var canClearTranscript: Bool {
        canCopyTranscript
            && (recordingStatus == .idle || recordingStatus == .ready)
            && !customActionState.isRunning
            && !chunkInFlight
    }

    /// The transcript editor is locked while an append-mode chunk composes
    /// onto a non-empty document: user edits there could not be re-split
    /// into "document + chunk", and the next stream snapshot would clobber
    /// them. Replace mode (or an append recording started from an empty
    /// transcript) keeps the historical editable-during-stream behavior.
    var isTranscriptChunkLocked: Bool {
        chunkInFlight && !composeBase.isEmpty
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
        activeTranscriptionAttemptID == nil
            && !customActionState.isRunning
            // Local recordings can be re-transcribed fully offline; cloud
            // strategies still need the AI Builder token.
            && (hasSavedAIBuilderToken || lastRecordingStrategy == .localQwen3ASR)
            && (recordingStatus == .recording || lastRecordingFileExists)
    }

    private var lastRecordingFileExists: Bool {
        guard let lastRecordingURL else { return false }
        return FileManager.default.fileExists(atPath: lastRecordingURL.path)
    }

    func startRecording() async {
        guard !customActionState.isRunning else { return }

        let strategy = transcriptionStrategy

        // The Local strategy is fully on-device: no AI Builder token is
        // needed, but the model weights must have been downloaded first.
        var cloudToken: String?
        if strategy == .localQwen3ASR {
            guard localModelStatus.isReady else {
                recordDiagnostic("recording_local_model_not_ready")
                presentRecordError("record.error.localModelNotDownloaded")
                return
            }
        } else {
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
            cloudToken = token
        }

        recordingStatus = .requestingPermission
        recordDiagnostic("recording_permission_request_started")
        guard await audioRecorder.requestPermission() else {
            recordDiagnostic("recording_permission_denied")
            presentRecordError("record.error.microphoneDenied")
            return
        }

        do {
            // Replace mode starts a fresh page; append mode keeps the
            // document and freezes it as the base the new chunk composes
            // onto (stream snapshots only ever replace the chunk, never
            // the document).
            activeTranscriptMode = transcriptMode
            composeBase = activeTranscriptMode == .append ? transcript : ""
            if activeTranscriptMode == .replace {
                transcript = ""
            }
            preResendDocument = nil
            preResendChunkLength = nil
            userEditedTranscriptDuringStream = false
            lastClipboardStatusKey = nil
            clearStreamCaptions()
            lastSavedRecording = nil
            shouldPresentSavedRecordingAlert = false
            openCodeSendStatus = .idle
            activeRecordingStrategy = strategy
            streamConnectionPhase = strategy.usesRealtimeTransport ? .connecting : .disconnected
            peakRms = 0
            activeAudioMs = 0
            signalTier = nil
            recordDiagnostic("recording_start_requested", metadata: ["hasToken": "true", "mode": strategy.diagnosticMode])

            if strategy.usesRealtimeTransport {
                guard let cloudToken else { return }
                await applyCurrentTranscriptionConfig(token: cloudToken)
                let session = try await voiceFlowClient.startSession(strategy: strategy)
                liveTranscriptionSession = session
                startLiveEventConsumer(for: session)
                startStreamHeartbeat()
            }

            let pcmBuffer = startCapturedPCMConsumer()
            try await audioRecorder.startRecording(strategy: strategy) { chunk in
                pcmBuffer.enqueue(chunk)
            }
            recordDiagnostic("recording_start_succeeded")
            resetRecordingTimer()
            startRecordingTimer()
            recordingStatus = .recording
            chunkInFlight = true
            // The new recording's audio does not become the resend target
            // until `stopRecording` persists it; a failure before that
            // point must not attribute a chunk boundary to it.
            chunkAudioIsResendTarget = false
            setScreenIdleTimer(disabled: true)
            startSignalBannerGraceTimer()
        } catch {
            await cancelCapturedPCMConsumer()
            await cancelLiveTranscriptionSession()
            composeBase = ""
            chunkInFlight = false
            chunkAudioIsResendTarget = false
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
        guard let attemptID = beginTranscriptionAttempt() else { return }
        defer {
            finishTranscriptionAttempt(attemptID)
            // Terminal failure exits (recorder stop failure, attempt
            // stolen, empty audio, signal tier failure, persistence
            // failure) all fall through here. The success funnel clears
            // `chunkInFlight` first, making this a no-op on success.
            settleFailedChunk()
        }
        stopRecordingTimer()
        cancelSignalBannerGraceTimer()
        setScreenIdleTimer(disabled: false)
        recordingStatus = .transcribing
        recordDiagnostic("recording_stop_requested")

        let audioURL: URL
        let strategy = activeRecordingStrategy
        do {
            audioURL = try await audioRecorder.stopRecording()
            await finishCapturedPCMConsumer()
        } catch {
            await cancelCapturedPCMConsumer()
            await cancelLiveTranscriptionSession()
            recordDiagnostic("recording_stop_failed", metadata: diagnosticMetadata(for: error))
            presentRecordError("record.error.transcriptionFailed")
            return
        }
        guard ownsTranscriptionAttempt(attemptID) else {
            try? FileManager.default.removeItem(at: audioURL)
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
            lastRecordingStrategy = strategy
            // The resend target is now THIS recording. Any last-chunk
            // boundary from a previous recording no longer describes the
            // resendable audio; invalidate it so a later resend cannot
            // replace the tail of an older, already-merged chunk. The
            // success merge (or the failure settle with a visible partial)
            // re-establishes the boundary attributed to this audio.
            lastChunkLength = nil
            chunkAudioIsResendTarget = true
        } catch {
            try? FileManager.default.removeItem(at: audioURL)
            await cancelLiveTranscriptionSession()
            recordDiagnostic("recording_persist_failed", metadata: diagnosticMetadata(for: error))
            presentRecordError("record.error.transcriptionFailed")
            return
        }
        try? FileManager.default.removeItem(at: audioURL)

        if strategy.usesRealtimeTransport {
            await finishLiveTranscriptionSession(attemptID: attemptID)
        } else {
            // Grok Batch (cloud upload) and Local (on-device) both finalize
            // from the persisted file; `finishBatchTranscription` dispatches
            // per-strategy inside `finishTranscriptionFromLastRecording`.
            await finishBatchTranscription(attemptID: attemptID)
        }
    }

    func handleScenePhaseChange(to phase: ScenePhase) async {
        switch phase {
        case .active:
            if recordingStatus == .recording {
                setScreenIdleTimer(disabled: true)
            }
            await liveTranscriptionSession?.ping()
        case .background:
            setScreenIdleTimer(disabled: false)
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
        guard let attemptID = beginTranscriptionAttempt() else { return }
        defer { finishTranscriptionAttempt(attemptID) }
        let shouldStopActiveRecording = recordingStatus == .recording
        recordingStatus = .transcribing
        openCodeSendStatus = .idle
        lastClipboardStatusKey = nil
        recordDiagnostic("recording_resend_requested")

        if shouldStopActiveRecording {
            let audioURL: URL
            do {
                stopRecordingTimer()
                setScreenIdleTimer(disabled: false)
                audioURL = try await audioRecorder.stopRecording()
                await finishCapturedPCMConsumer()
                // The in-flight chunk's audio is now this just-stopped
                // recording, which is not the resend target until persist
                // succeeds below.
                chunkAudioIsResendTarget = false
            } catch {
                await cancelCapturedPCMConsumer()
                await cancelLiveTranscriptionSession()
                recordDiagnostic("recording_resend_stop_failed", metadata: diagnosticMetadata(for: error))
                settleFailedChunk()
                presentRecordError("record.error.transcriptionFailed")
                return
            }
            guard ownsTranscriptionAttempt(attemptID) else {
                try? FileManager.default.removeItem(at: audioURL)
                settleFailedChunk()
                return
            }

            let audioMetadata = audioFileMetadata(for: audioURL)
            if audioMetadata["byteCount"] == "0" {
                try? FileManager.default.removeItem(at: audioURL)
                await cancelLiveTranscriptionSession()
                recordDiagnostic("recording_resend_audio_file_empty")
                settleFailedChunk()
                presentRecordError("record.error.transcriptionFailed")
                return
            }

            do {
                lastRecordingURL = try persistLastRecording(from: audioURL)
                lastRecordingStrategy = activeRecordingStrategy
                // Same rule as the fresh-stop path: the resend target is now
                // this audio, so an older merged-chunk boundary no longer
                // describes it.
                lastChunkLength = nil
                chunkAudioIsResendTarget = true
            } catch {
                try? FileManager.default.removeItem(at: audioURL)
                await cancelLiveTranscriptionSession()
                recordDiagnostic("recording_resend_persist_failed", metadata: diagnosticMetadata(for: error))
                settleFailedChunk()
                presentRecordError("record.error.transcriptionFailed")
                return
            }
            try? FileManager.default.removeItem(at: audioURL)
            await cancelLiveTranscriptionSession()
            guard ownsTranscriptionAttempt(attemptID) else {
                settleFailedChunk()
                return
            }
        } else {
            // Rescue path: transcription is stuck (e.g. a hung live WebSocket
            // session that never returned). Force-close any active session so we
            // start the re-transcription from a clean state instead of layering
            // on top of the stalled one.
            await cancelLiveTranscriptionSession()
            guard ownsTranscriptionAttempt(attemptID) else {
                settleFailedChunk()
                return
            }
        }

        // Chunk composition for the re-transcription.
        //
        // Fresh resend (idle/ready): the new chunk replaces the previously
        // merged chunk, so the base is the document minus its last chunk
        // (boundary from `lastChunkLength`; when unknown, fall back to
        // end-append rather than clobbering the document). The restored
        // boundary on failure is the merged one — the pre-resend document's
        // tail.
        //
        // Resend during an active recording (or a stuck finalize): the live
        // chunk is still in flight with its own `composeBase`; the
        // re-transcription replaces that same chunk region. The pre-resend
        // document's tail is the visible live chunk, so its length is the
        // boundary a failure restore must remember (a merged boundary from
        // an older recording would point into the live chunk).
        activeTranscriptMode = transcriptMode
        if activeTranscriptMode == .append {
            preResendDocument = transcript
            let visible = chunkInFlight ? visibleChunkText() : ""
            preResendChunkLength = visible.isEmpty ? (chunkInFlight ? nil : lastChunkLength) : visible.count
            if !chunkInFlight {
                composeBase = resendComposeBase()
            }
        } else {
            preResendDocument = nil
            preResendChunkLength = nil
            if !chunkInFlight {
                composeBase = ""
            }
        }
        chunkInFlight = true

        if let bulkText = await finishTranscriptionFromLastRecording(
            attemptID: attemptID,
            presentErrorOnFailure: true
        ) {
            completeStopTranscriptionSuccess(text: bulkText, mode: "resend", attemptID: attemptID)
        } else {
            // Re-transcription failed: restore exactly what the user saw
            // before the resend (append), or keep the last partial
            // (replace, historical behavior).
            settleFailedResend()
        }
    }

    func presentRecordError(_ key: String) {
        recordErrorAlertKey = key
        recordingStatus = .idle
        stopRecordingTimer()
        setScreenIdleTimer(disabled: false)
    }

    func setScreenIdleTimer(disabled: Bool) {
        screenIdleController.setIdleTimerDisabled(disabled)
    }

}

private extension VoiceFlowRecordingStrategy {
    var diagnosticMode: String {
        switch self {
        case .openAIRealtime: "stream"
        case .gptLiveTranscribe: "gpt_live_transcribe"
        case .grokBatch: "grok_batch"
        case .localQwen3ASR: "local_asr"
        }
    }
}
