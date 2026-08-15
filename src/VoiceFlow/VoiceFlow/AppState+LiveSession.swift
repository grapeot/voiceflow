import Foundation
#if canImport(UIKit)
import UIKit
#endif
import VoiceFlowKit

final class OrderedPCMChunkBuffer: @unchecked Sendable {
    let signals: AsyncStream<Void>

    private let lock = NSLock()
    private let continuation: AsyncStream<Void>.Continuation
    private let maxPendingChunks: Int
    private var chunks: [Data] = []
    private var isFinished = false

    init(maxPendingChunks: Int = 32) {
        precondition(maxPendingChunks > 0)
        var capturedContinuation: AsyncStream<Void>.Continuation?
        signals = AsyncStream(bufferingPolicy: .bufferingNewest(1)) {
            capturedContinuation = $0
        }
        continuation = capturedContinuation!
        self.maxPendingChunks = maxPendingChunks
    }

    func enqueue(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        if chunks.count < maxPendingChunks {
            chunks.append(chunk)
        } else {
            chunks[chunks.count - 1].append(chunk)
        }
        lock.unlock()
        continuation.yield(())
    }

    func popFirst() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard !chunks.isEmpty else { return nil }
        return chunks.removeFirst()
    }

    func finish() {
        lock.lock()
        let shouldFinish = !isFinished
        isFinished = true
        lock.unlock()
        if shouldFinish {
            continuation.finish()
        }
    }

    var pendingChunkCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return chunks.count
    }
}

/// Live transcription session bridge. Wires the kit's `VoiceFlowSession`
/// (events / audio chunks / heartbeat / finalize / cancel) into AppState's
/// publishable state. Also handles the bulk-fallback `transcribe(audioFile:)`
/// path used by both stop-recording and resend flows.
///
/// This is the most stateful piece of AppState — keeping it in its own
/// file makes the recording lifecycle (`startRecording` / `stopRecording`)
/// in the main file shorter and easier to follow.
extension AppState {
    func beginTranscriptionAttempt() -> UUID? {
        guard activeTranscriptionAttemptID == nil else { return nil }
        let attemptID = UUID()
        activeTranscriptionAttemptID = attemptID
        return attemptID
    }

    func ownsTranscriptionAttempt(_ attemptID: UUID) -> Bool {
        activeTranscriptionAttemptID == attemptID
    }

    func finishTranscriptionAttempt(_ attemptID: UUID) {
        guard ownsTranscriptionAttempt(attemptID) else { return }
        if partialTranscriptAttemptID == attemptID {
            partialTranscriptAttemptID = nil
        }
        activeTranscriptionAttemptID = nil
    }

    func invalidateTranscriptionAttempt() {
        partialTranscriptAttemptID = nil
        activeTranscriptionAttemptID = nil
    }

    func acceptsPartialTranscript(for attemptID: UUID) -> Bool {
        ownsTranscriptionAttempt(attemptID) && partialTranscriptAttemptID == attemptID
    }

    func startCapturedPCMConsumer() -> OrderedPCMChunkBuffer {
        capturedPCMBuffer?.finish()
        capturedPCMConsumerTask?.cancel()

        let buffer = OrderedPCMChunkBuffer()
        capturedPCMBuffer = buffer
        capturedPCMConsumerTask = Task { @MainActor [weak self, buffer] in
            for await _ in buffer.signals {
                while let chunk = buffer.popFirst() {
                    guard !Task.isCancelled, let self else { return }
                    await self.handleCapturedPCMChunk(chunk)
                }
            }
            while let chunk = buffer.popFirst() {
                guard !Task.isCancelled, let self else { return }
                await self.handleCapturedPCMChunk(chunk)
            }
        }
        return buffer
    }

    func finishCapturedPCMConsumer() async {
        capturedPCMBuffer?.finish()
        await capturedPCMConsumerTask?.value
        capturedPCMBuffer = nil
        capturedPCMConsumerTask = nil
    }

    func cancelCapturedPCMConsumer() async {
        capturedPCMBuffer?.finish()
        capturedPCMConsumerTask?.cancel()
        await capturedPCMConsumerTask?.value
        capturedPCMBuffer = nil
        capturedPCMConsumerTask = nil
    }

    /// Refresh the kit-side config with the current token + prompt + terms
    /// from Settings. `tokenProvider` is rebuilt to close over the token
    /// value (rather than re-reading Keychain on every call) so the
    /// session sees a consistent token even if the user clears it
    /// mid-session.
    func applyCurrentTranscriptionConfig(token: String) async {
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
    func startLiveEventConsumer(for session: VoiceFlowSession) {
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

    func finishTranscriptionFromLastRecording(
        attemptID: UUID,
        presentErrorOnFailure: Bool = true
    ) async -> String? {
        guard ownsTranscriptionAttempt(attemptID) else { return nil }
        guard let audioURL = lastRecordingURL else {
            if presentErrorOnFailure {
                presentRecordError("record.error.transcriptionFailed")
            }
            return nil
        }

        let strategy = lastRecordingStrategy

        // On-device path: no token, no network. The engine transcribes the
        // persisted recording directly and returns the final text.
        if strategy == .localQwen3ASR {
            do {
                recordDiagnostic("transcription_started", metadata: ["mode": "local_asr"])
                let text = try await localAsrEngine.transcribe(audioFile: audioURL)
                guard ownsTranscriptionAttempt(attemptID) else { return nil }
                recordDiagnostic(
                    "transcription_succeeded",
                    metadata: ["characterCount": "\(text.count)", "mode": "local_asr"]
                )
                return text
            } catch {
                guard ownsTranscriptionAttempt(attemptID) else { return nil }
                recordDiagnostic(
                    "transcription_local_failed",
                    metadata: ["reason": String(describing: error)]
                )
                if presentErrorOnFailure {
                    presentRecordError("record.error.localTranscriptionFailed")
                }
                return nil
            }
        }

        guard let token = try? keychainStore.readString(for: Self.tokenKey), !token.isEmpty else {
            recordDiagnostic("recording_missing_token", metadata: ["hasToken": "false"])
            if presentErrorOnFailure {
                presentRecordError("record.error.missingToken")
            }
            return nil
        }

        do {
            recordDiagnostic("transcription_started", metadata: ["hasToken": "true", "mode": strategy == .grokBatch ? "grok_batch" : "bulk"])
            await applyCurrentTranscriptionConfig(token: token)
            guard ownsTranscriptionAttempt(attemptID) else { return nil }
            partialTranscriptAttemptID = attemptID
            defer {
                if partialTranscriptAttemptID == attemptID {
                    partialTranscriptAttemptID = nil
                }
            }
            let result = try await voiceFlowClient.transcribe(audioFile: audioURL, strategy: strategy) { [weak self] partial in
                Task { @MainActor in
                    guard let self, self.acceptsPartialTranscript(for: attemptID) else { return }
                    self.applyStreamedTranscript(partial)
                }
            }
            guard ownsTranscriptionAttempt(attemptID) else { return nil }
            let transcribedText = result.text
            recordDiagnostic("transcription_succeeded", metadata: ["characterCount": "\(transcribedText.count)", "mode": strategy == .grokBatch ? "grok_batch" : "bulk"])
            return transcribedText
        } catch {
            guard ownsTranscriptionAttempt(attemptID) else { return nil }
            recordDiagnostic(transcriptionFailureEventName(for: error), metadata: diagnosticMetadata(for: error))
            if presentErrorOnFailure {
                presentRecordError("record.error.transcriptionFailed")
            }
            return nil
        }
    }

    /// Apply a streamed transcript value to `transcript` in a way that avoids
    /// the per-partial flash the public app used to show.
    ///
    /// Streaming hands us the *whole* transcript so far on every partial.
    /// Assigning a brand-new String to the `@Published` that `TextEditor` binds
    /// to makes UITextView treat it as a fresh value and reset its contents
    /// (and selection/scroll) — that reset is the flicker. The private app
    /// avoids it by appending, which keeps the existing prefix identical.
    ///
    /// So: if the new value just extends what's already there, only append the
    /// delta; if it diverges, replace; if it's unchanged, skip the write
    /// entirely (a no-op assignment still churns the binding).
    func applyStreamedTranscript(_ content: String) {
        if content == transcript { return }
        if content.hasPrefix(transcript) {
            transcript.append(contentsOf: content.dropFirst(transcript.count))
        } else {
            transcript = content
        }
    }

    func handleStreamEvent(_ event: VoiceFlowEvent) {
        switch event {
        case .partialTranscript(let content):
            if recordingStatus == .recording {
                guard activeRecordingStrategy == .gptLiveTranscribe else { return }
                if !userEditedTranscriptDuringStream {
                    applyStreamedTranscript(content)
                }
                return
            }
            guard let attemptID = activeTranscriptionAttemptID,
                  acceptsPartialTranscript(for: attemptID) else { return }
            if !userEditedTranscriptDuringStream {
                applyStreamedTranscript(content)
            }
        case .phaseChanged(let phase):
            streamConnectionPhase = phase
            switch phase {
            case .connected, .connecting:
                if recordingStatus == .recording,
                   persistentStreamCaptionKey == StreamCaptionKey.reconnecting {
                    setPersistentStreamCaption(nil)
                    flashTransientStreamCaption(StreamCaptionKey.reconnected)
                }
            case .recovering:
                if recordingStatus == .recording {
                    setPersistentStreamCaption(StreamCaptionKey.reconnecting)
                }
            case .disconnected, .generating:
                break
            }
        case .recoveryStarted:
            streamConnectionPhase = .recovering
            if recordingStatus == .recording {
                setPersistentStreamCaption(StreamCaptionKey.reconnecting)
            }
        case .recoveryFailed(let message):
            if isTranscriptionTeardown {
                return
            }
            recordDiagnostic("transcription_stream_recovery_failed", metadata: ["reason": message])
            streamConnectionPhase = .disconnected
            if recordingStatus == .recording {
                setPersistentStreamCaption(StreamCaptionKey.streamDisconnected)
            } else if recordingStatus == .transcribing {
                setPersistentStreamCaption(StreamCaptionKey.streamDisconnected)
            } else if !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                setPersistentStreamCaption(StreamCaptionKey.streamDisconnected)
            } else {
                presentRecordError("record.error.transcriptionFailed")
            }
        }
    }

    func handleCapturedPCMChunk(_ chunk: Data) async {
        updateAudioLevel(from: chunk)
        if activeRecordingStrategy.usesRealtimeTransport {
            await liveTranscriptionSession?.sendAudioChunk(chunk)
        }
    }

    /// Compute RMS of a PCM16 little-endian chunk via VoiceFlowKit's metering
    /// helper, then feed it into an exponential moving average so the waveform
    /// never jitters on short silences mid-syllable. 30 % new sample,
    /// 70 % carried — short attack, slow release.
    /// Also accumulates peakRms and activeAudioMs for signal-quality detection.
    private func updateAudioLevel(from chunk: Data) {
        let normalized = VoiceFlowAudioMetering.normalizedLevel(fromPCM16LE: chunk)
        audioLevel = audioLevel * 0.7 + normalized * 0.3

        guard recordingStatus == .recording
                || recordingStatus == .requestingPermission
                || recordingStatus == .transcribing else { return }
        let rawRms = VoiceFlowAudioMetering.rmsLevel(fromPCM16LE: chunk)
        if rawRms > peakRms { peakRms = rawRms }
        if rawRms >= Self.speechThreshold {
            let sampleCount = chunk.count / 2
            let sampleRate = 24000.0
            activeAudioMs += Double(sampleCount) / sampleRate * 1000
            if persistentStreamCaptionKey == SignalCaptionKey.noSignalLive {
                setPersistentStreamCaption(nil)
            }
        }
    }

    private func updateTranscriptDuringFinalize(_ partial: String) {
        applyStreamedTranscript(partial)
    }

    // MARK: - Signal quality gate

    /// Evaluate signal quality from peakRms and activeAudioMs accumulated
    /// during recording. Called at Stop time before committing audio.
    func evaluateSignalTier() -> SignalTier {
        // Tier 1: no speech detected at all. We check activeAudioMs rather
        // than peakRms alone, because iOS mic noise floor can push peakRms
        // above silenceFloor even when the user never spoke. The real
        // signal is whether any frame crossed the speech threshold.
        if activeAudioMs < 100 {
            return .tier1NoSignal
        }
        if activeAudioMs < Self.activeAudioShortMs {
            return .tier2ShortAudio
        }
        return .tier3Normal
    }

    /// Start a grace timer; if no speech is detected after the grace window,
    /// show a live "no signal" caption to warn the user mid-recording.
    func startSignalBannerGraceTimer() {
        signalBannerGraceTask?.cancel()
        signalBannerGraceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.signalBannerGraceMs))
            guard !Task.isCancelled, let self else { return }
            guard self.recordingStatus == .recording else { return }
            guard self.activeAudioMs < 1 else { return }
            self.setPersistentStreamCaption(SignalCaptionKey.noSignalLive)
        }
    }

    func cancelSignalBannerGraceTimer() {
        signalBannerGraceTask?.cancel()
        signalBannerGraceTask = nil
    }

    private func makeFinalizePartialHandler(attemptID: UUID) -> @Sendable (String) -> Void {
        { [weak self] partial in
            Task { @MainActor [weak self] in
                guard let self, self.acceptsPartialTranscript(for: attemptID) else { return }
                updateTranscriptDuringFinalize(partial)
            }
        }
    }

    func finishLiveTranscriptionSession(attemptID: UUID) async {
        guard ownsTranscriptionAttempt(attemptID) else { return }
        stopStreamHeartbeat()
        isTranscriptionTeardown = true
        defer { isTranscriptionTeardown = false }

        guard let session = liveTranscriptionSession else {
            recordDiagnostic("transcription_finalize_failed", metadata: ["reason": "noSession"])
            completeStopTranscriptionFailure(reason: "noSession", attemptID: attemptID)
            return
        }

        recordDiagnostic("transcription_finalize_started", metadata: ["hasToken": "true", "mode": "stream"])
        var streamText = ""
        partialTranscriptAttemptID = attemptID
        do {
            streamText = try await session.commitAndStop(
                onPartialTranscript: makeFinalizePartialHandler(attemptID: attemptID)
            )
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
        if partialTranscriptAttemptID == attemptID {
            partialTranscriptAttemptID = nil
        }

        guard ownsTranscriptionAttempt(attemptID) else {
            await session.cancel()
            return
        }
        await cancelLiveTranscriptionSession()

        if isUsableTranscript(streamText) {
            completeStopTranscriptionSuccess(text: streamText, mode: "stream", attemptID: attemptID)
            return
        }

        if activeRecordingStrategy == .gptLiveTranscribe {
            completeStopTranscriptionFailure(reason: "gptLiveFinalizeFailed", attemptID: attemptID)
            return
        }

        let fallbackReason = streamText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "emptyStream" : "tooShort"
        recordDiagnostic("transcription_fallback_bulk", metadata: ["reason": fallbackReason])
        if let bulkText = await finishTranscriptionFromLastRecording(
            attemptID: attemptID,
            presentErrorOnFailure: false
        ),
           isUsableTranscript(bulkText) {
            completeStopTranscriptionSuccess(text: bulkText, mode: "bulk", attemptID: attemptID)
            return
        }

        completeStopTranscriptionFailure(reason: "allPathsFailed", attemptID: attemptID)
    }

    func finishBatchTranscription(attemptID: UUID) async {
        guard ownsTranscriptionAttempt(attemptID) else { return }
        let isLocal = lastRecordingStrategy == .localQwen3ASR
        // Local ASR often returns 1–2 CJK characters ("你好", "好的"). The
        // cloud >3-character gate would treat those as failures.
        let usable: (String) -> Bool = isLocal
            ? { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            : isUsableTranscript
        let text = await finishTranscriptionFromLastRecording(
            attemptID: attemptID,
            presentErrorOnFailure: false
        )
        if let text, usable(text) {
            completeStopTranscriptionSuccess(
                text: text,
                mode: isLocal ? "local_asr" : "grok_batch",
                attemptID: attemptID
            )
        } else if isLocal, ownsTranscriptionAttempt(attemptID) {
            let reason = text == nil ? "localAsrFailed" : "localEmptyTranscript"
            recordDiagnostic("transcription_stop_failed", metadata: ["reason": reason])
            presentRecordError(
                text == nil
                    ? "record.error.localTranscriptionFailed"
                    : "record.error.localEmptyTranscript"
            )
        } else if !isLocal {
            completeStopTranscriptionFailure(
                reason: "grokBatchFailed",
                attemptID: attemptID
            )
        }
    }

    // MARK: - Local model download

    /// Download the on-device model weights with progress reporting.
    /// A healthy in-flight download ignores further taps. A stalled one
    /// (no progress for 20s) is cancelled and restarted so Retry after a
    /// background kill cannot sit at 0% forever.
    func downloadLocalModel() {
        if case .ready = localModelStatus { return }
        if localModelStatus.isInFlight, localModelDownloadTask != nil, !isLocalModelDownloadStalled {
            return
        }
        localModelDownloadTask?.cancel()
        localModelDownloadTask = nil

        let seeded = max(0, min(1, localAsrEngine.existingDownloadProgress()))
        localModelStatus = seeded > 0 ? .downloading(progress: seeded) : .preparing
        localModelLastProgressAt = Date()
        recordDiagnostic("local_model_download_started")

        #if os(iOS)
        var backgroundTask = UIBackgroundTaskIdentifier.invalid
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "local-asr-model-download") { [weak self] in
            self?.interruptLocalModelDownload(reason: .interrupted)
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
                backgroundTask = .invalid
            }
        }
        #endif

        localModelDownloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.localAsrEngine.downloadModel { update in
                    Task { @MainActor [weak self] in
                        guard let self, self.localModelStatus.isInFlight else { return }
                        self.localModelLastProgressAt = Date()
                        if update.isPreparing, update.fraction <= 0 {
                            self.localModelStatus = .preparing
                        } else {
                            self.localModelStatus = .downloading(progress: max(0, min(1, update.fraction)))
                        }
                    }
                }
                await MainActor.run { [weak self] in
                    guard let self, self.localModelStatus.isInFlight else { return }
                    self.localModelStatus = .ready
                    self.recordDiagnostic("local_model_download_succeeded")
                }
            } catch is CancellationError {
                await MainActor.run { [weak self] in
                    self?.finishCancelledLocalModelDownload()
                }
            } catch LocalAsrEngineError.interrupted {
                await MainActor.run { [weak self] in
                    self?.finishCancelledLocalModelDownload()
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.localModelStatus.isInFlight else { return }
                    self.localModelStatus = .failed(message: String(describing: error))
                    self.recordDiagnostic(
                        "local_model_download_failed",
                        metadata: ["reason": String(describing: error)]
                    )
                }
            }
            await MainActor.run { [weak self] in
                self?.localModelDownloadTask = nil
                self?.localModelLastProgressAt = nil
                #if os(iOS)
                if backgroundTask != .invalid {
                    UIApplication.shared.endBackgroundTask(backgroundTask)
                    backgroundTask = .invalid
                }
                #endif
            }
        }
    }

    func interruptLocalModelDownload(reason: LocalAsrEngineError = .interrupted) {
        guard localModelStatus.isInFlight else { return }
        localModelDownloadTask?.cancel()
        recordDiagnostic("local_model_download_paused", metadata: ["reason": String(describing: reason)])
    }

    private func finishCancelledLocalModelDownload() {
        guard localModelStatus.isInFlight else { return }
        localModelStatus = .paused
        localModelLastProgressAt = nil
    }

    private func isUsableTranscript(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).count > 3
    }

    func completeStopTranscriptionSuccess(text: String, mode: String, attemptID: UUID) {
        guard ownsTranscriptionAttempt(attemptID) else { return }
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

    private func completeStopTranscriptionFailure(reason: String, attemptID: UUID) {
        guard ownsTranscriptionAttempt(attemptID) else { return }
        recordDiagnostic("transcription_stop_failed", metadata: ["reason": reason])
        presentRecordError("record.error.transcriptionFailed")
    }

    func cancelLiveTranscriptionSession() async {
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

    func startStreamHeartbeat() {
        stopStreamHeartbeat()
        streamHeartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.streamHeartbeatIntervalSeconds))
                guard !Task.isCancelled, let self else { return }
                await self.liveTranscriptionSession?.ping()
            }
        }
    }

    func stopStreamHeartbeat() {
        streamHeartbeatTask?.cancel()
        streamHeartbeatTask = nil
    }
}
