import Foundation
import VoiceFlowKit

/// Live transcription session bridge. Wires the kit's `VoiceFlowSession`
/// (events / audio chunks / heartbeat / finalize / cancel) into AppState's
/// publishable state. Also handles the bulk-fallback `transcribe(audioFile:)`
/// path used by both stop-recording and resend flows.
///
/// This is the most stateful piece of AppState — keeping it in its own
/// file makes the recording lifecycle (`startRecording` / `stopRecording`)
/// in the main file shorter and easier to follow.
extension AppState {
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

    func finishTranscriptionFromLastRecording(presentErrorOnFailure: Bool = true) async -> String? {
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

    func handleStreamEvent(_ event: VoiceFlowEvent) {
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

    func handleCapturedPCMChunk(_ chunk: Data) async {
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

    func finishLiveTranscriptionSession() async {
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

    /// Stream-mode clipboard write. Throttled so we don't pin clipboard
    /// updates for tiny per-token deltas; the throttle window is 1 s,
    /// and we only write when the hash actually changed.
    func throttledStreamClipboardWrite(_ text: String) {
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
}
