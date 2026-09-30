//
//  TranscriptModeTests.swift
//  VoiceFlowTests
//
//  Covers the append transcript mode: the document + pending-chunk model,
//  the mode switch, the trash button (clear-to-history), and the failure
//  settlement rules. See docs/append_transcript_design.md.
//

import Foundation
import Testing
@testable import VoiceFlow
@testable import VoiceFlowKit

@Suite(.serialized)
@MainActor
struct TranscriptModeTests {

    private func resetTranscriptionStrategyDefault() {
        UserDefaults.standard.removeObject(forKey: "transcriptionStrategy")
    }

    // MARK: - Composition rules

    @Test func composeTranscriptSeparatorRules() {
        #expect(AppState.composeTranscript(base: "", chunk: "chunk") == "chunk")
        #expect(AppState.composeTranscript(base: "base", chunk: "") == "base")
        #expect(AppState.composeTranscript(base: "", chunk: "") == "")
        // Single line separator; no timestamp, no blank line.
        #expect(AppState.composeTranscript(base: "base", chunk: "chunk") == "base\nchunk")
        // A document that already ends in a newline is not doubled up.
        #expect(AppState.composeTranscript(base: "base\n", chunk: "chunk") == "base\nchunk")
        // Character-based, so CJK documents behave identically.
        #expect(AppState.composeTranscript(base: "你好", chunk: "世界") == "你好\n世界")
    }

    // MARK: - Mode defaults and scoping

    @Test func transcriptModeDefaultsToReplaceAndIsSessionScoped() {
        let state = AppState(keychainStore: InMemoryKeychainStore())
        #expect(state.transcriptMode == .replace)
        #expect(state.activeTranscriptMode == .replace)
        // Session scoped: switching must not touch UserDefaults, and a
        // fresh state must default back to replace.
        UserDefaults.standard.removeObject(forKey: "voiceflowTranscriptMode")
        state.transcriptMode = .append
        #expect(UserDefaults.standard.string(forKey: "voiceflowTranscriptMode") == nil)
        #expect(AppState(keychainStore: InMemoryKeychainStore()).transcriptMode == .replace)
        #expect(state.canChangeTranscriptMode == true)
        #expect(state.isTranscriptChunkLocked == false)
    }

    @Test func transcriptModeLockedWhileChunkInFlight() {
        let state = AppState(keychainStore: InMemoryKeychainStore())
        state.transcriptMode = .append
        state.transcript = "document"
        state.composeBase = "document"
        state.chunkInFlight = true
        #expect(state.isTranscriptChunkLocked == true)
        #expect(state.canClearTranscript == false)
        state.composeBase = ""
        #expect(state.isTranscriptChunkLocked == false)
    }

    // MARK: - Full flow: append

    @Test func appendModeStartKeepsDocumentAndMergesOnSuccess() async throws {
        resetTranscriptionStrategyDefault()
        defer { resetTranscriptionStrategyDefault() }
        let keychain = InMemoryKeychainStore()
        let recorder = MockAudioRecorder()
        let (client, _) = makeStubVoiceFlowClient(liveResult: .success("second chunk"))
        let state = AppState(
            keychainStore: keychain,
            audioRecorder: recorder,
            voiceFlowClient: client,
            clipboardWriter: MockClipboardWriter()
        )

        state.saveAIBuilderToken("fake-token")
        state.transcriptMode = .append
        state.transcript = "first chunk"

        await state.startRecording()
        #expect(state.recordingStatus == .recording)
        // Append mode keeps the document; replace mode would have cleared it.
        #expect(state.transcript == "first chunk")
        #expect(state.composeBase == "first chunk")
        #expect(state.chunkInFlight == true)
        #expect(state.activeTranscriptMode == .append)
        #expect(state.isTranscriptChunkLocked == true)

        // The mode is captured at Start: switching mid-recording must not
        // change how this recording merges.
        state.transcriptMode = .replace

        await state.stopRecording()
        #expect(state.recordingStatus == .ready)
        #expect(state.transcript == "first chunk\nsecond chunk")
        #expect(state.lastChunkLength == "second chunk".count)
        #expect(state.composeBase.isEmpty)
        #expect(state.chunkInFlight == false)
        #expect(state.isTranscriptChunkLocked == false)
        // History holds a whole-document snapshot, newest first.
        #expect(state.transcriptHistory.currentIndex == 0)
        #expect(state.transcriptHistory.currentEntry == "first chunk\nsecond chunk")
    }

    @Test func appendModeFromEmptyDocumentMergesToJustTheChunk() async throws {
        resetTranscriptionStrategyDefault()
        defer { resetTranscriptionStrategyDefault() }
        let keychain = InMemoryKeychainStore()
        let recorder = MockAudioRecorder()
        let (client, _) = makeStubVoiceFlowClient(liveResult: .success("only chunk"))
        let state = AppState(
            keychainStore: keychain,
            audioRecorder: recorder,
            voiceFlowClient: client,
            clipboardWriter: MockClipboardWriter()
        )

        state.saveAIBuilderToken("fake-token")
        state.transcriptMode = .append

        await state.startRecording()
        #expect(state.composeBase == "")
        #expect(state.isTranscriptChunkLocked == false)

        await state.stopRecording()
        #expect(state.transcript == "only chunk")
        #expect(state.recordingStatus == .ready)
    }

    // MARK: - Full flow: replace regression

    @Test func replaceModeStartClearsDocumentAndReplacesOnSuccess() async throws {
        resetTranscriptionStrategyDefault()
        defer { resetTranscriptionStrategyDefault() }
        let keychain = InMemoryKeychainStore()
        let recorder = MockAudioRecorder()
        let (client, _) = makeStubVoiceFlowClient(liveResult: .success("new result text"))
        let state = AppState(
            keychainStore: keychain,
            audioRecorder: recorder,
            voiceFlowClient: client,
            clipboardWriter: MockClipboardWriter()
        )

        state.saveAIBuilderToken("fake-token")
        state.transcript = "old document"

        await state.startRecording()
        #expect(state.transcript.isEmpty)
        #expect(state.composeBase == "")
        #expect(state.activeTranscriptMode == .replace)

        await state.stopRecording()
        #expect(state.transcript == "new result text")
        // Replace mode treats the whole page as the last chunk, so a later
        // resend (even after switching to append) replaces it.
        #expect(state.lastChunkLength == "new result text".count)
        #expect(state.transcriptHistory.currentEntry == "new result text")
    }

    // MARK: - Streaming snapshots only touch the chunk region

    @Test func streamSnapshotsFillOnlyTheChunkRegionInAppendMode() {
        let state = AppState(keychainStore: InMemoryKeychainStore())
        state.transcriptMode = .append
        state.transcript = "document text"
        state.composeBase = "document text"
        state.chunkInFlight = true

        // Live snapshots replace the whole in-flight chunk; the document
        // prefix stays intact under every update.
        state.applyStreamedTranscript("hel")
        #expect(state.transcript == "document text\nhel")
        state.applyStreamedTranscript("hello")
        #expect(state.transcript == "document text\nhello")
        // A correction shortens the chunk tail.
        state.applyStreamedTranscript("hell")
        #expect(state.transcript == "document text\nhell")
        // A divergent snapshot replaces the chunk only.
        state.applyStreamedTranscript("completely different")
        #expect(state.transcript == "document text\ncompletely different")
        // Empty snapshots never touch the document.
        state.applyStreamedTranscript("")
        #expect(state.transcript == "document text\ncompletely different")
    }

    @Test func streamSnapshotsIgnoreStaleFramesAfterSettle() {
        let state = AppState(keychainStore: InMemoryKeychainStore())
        state.transcript = "document text"
        state.composeBase = "document text"
        state.chunkInFlight = true
        state.applyStreamedTranscript("partial")
        state.chunkInFlight = false
        state.applyStreamedTranscript("stale frame")
        #expect(state.transcript == "document text\npartial")
    }

    // MARK: - Failure settlement

    @Test func failedFinalizeKeepsVisiblePartialInAppendMode() async throws {
        resetTranscriptionStrategyDefault()
        defer { resetTranscriptionStrategyDefault() }
        let keychain = InMemoryKeychainStore()
        let recorder = MockAudioRecorder()
        let (client, _) = makeStubVoiceFlowClient(
            liveResult: .failure(VoiceFlowError.connectionLost("finalize failed")),
            bulkResult: .failure(VoiceFlowError.emptyTranscript)
        )
        let state = AppState(
            keychainStore: keychain,
            audioRecorder: recorder,
            voiceFlowClient: client,
            clipboardWriter: MockClipboardWriter()
        )

        state.saveAIBuilderToken("fake-token")
        state.transcriptMode = .append
        state.transcript = "document text"
        await state.startRecording()
        // Live text already on screen for the in-flight chunk.
        state.applyStreamedTranscript("partial words")
        #expect(state.transcript == "document text\npartial words")

        await state.stopRecording()
        #expect(state.recordingStatus == .idle)
        #expect(state.recordErrorAlertKey == "record.error.transcriptionFailed")
        // The visible partial is folded into the document; nothing lost.
        #expect(state.transcript == "document text\npartial words")
        #expect(state.isTranscriptChunkLocked == false)
        #expect(state.chunkInFlight == false)
    }

    @Test func failedFinalizeWithEmptyChunkLeavesDocumentUnchanged() async throws {
        resetTranscriptionStrategyDefault()
        defer { resetTranscriptionStrategyDefault() }
        let keychain = InMemoryKeychainStore()
        let recorder = MockAudioRecorder()
        let (client, _) = makeStubVoiceFlowClient(
            liveResult: .failure(VoiceFlowError.connectionLost("finalize failed")),
            bulkResult: .failure(VoiceFlowError.emptyTranscript)
        )
        let state = AppState(
            keychainStore: keychain,
            audioRecorder: recorder,
            voiceFlowClient: client,
            clipboardWriter: MockClipboardWriter()
        )

        state.saveAIBuilderToken("fake-token")
        state.transcriptMode = .append
        state.transcript = "document text"
        await state.startRecording()

        await state.stopRecording()
        #expect(state.recordingStatus == .idle)
        // Empty chunk: the document is untouched.
        #expect(state.transcript == "document text")
        #expect(state.chunkInFlight == false)
    }

    // MARK: - Resend

    @Test func resendInAppendModeReplacesTheLastChunk() async throws {
        resetTranscriptionStrategyDefault()
        defer { resetTranscriptionStrategyDefault() }
        let keychain = InMemoryKeychainStore()
        let recorder = MockAudioRecorder()
        let (client, mock) = makeStubVoiceFlowClient(
            liveResult: .success("second chunk"),
            bulkResult: .success("second chunk fixed")
        )
        let state = AppState(
            keychainStore: keychain,
            audioRecorder: recorder,
            voiceFlowClient: client,
            clipboardWriter: MockClipboardWriter()
        )

        state.saveAIBuilderToken("fake-token")
        state.transcriptMode = .append
        state.transcript = "first chunk"
        await state.startRecording()
        await state.stopRecording()
        #expect(state.transcript == "first chunk\nsecond chunk")
        #expect(state.lastChunkLength == "second chunk".count)

        await mock.setBulkResult(.success("second chunk fixed"))
        await state.resendLastRecording()
        // The re-transcription replaces the last chunk, not append a copy.
        #expect(state.recordingStatus == .ready)
        #expect(state.transcript == "first chunk\nsecond chunk fixed")
        #expect(state.lastChunkLength == "second chunk fixed".count)
        #expect(state.transcriptHistory.currentEntry == "first chunk\nsecond chunk fixed")
    }

    @Test func failedResendInAppendModeRestoresPreResendDocument() async throws {
        resetTranscriptionStrategyDefault()
        defer { resetTranscriptionStrategyDefault() }
        let keychain = InMemoryKeychainStore()
        let recorder = MockAudioRecorder()
        let (client, mock) = makeStubVoiceFlowClient(
            liveResult: .success("second chunk"),
            bulkResult: .failure(VoiceFlowError.emptyTranscript)
        )
        let state = AppState(
            keychainStore: keychain,
            audioRecorder: recorder,
            voiceFlowClient: client,
            clipboardWriter: MockClipboardWriter()
        )

        state.saveAIBuilderToken("fake-token")
        state.transcriptMode = .append
        state.transcript = "first chunk"
        await state.startRecording()
        await state.stopRecording()
        #expect(state.transcript == "first chunk\nsecond chunk")
        #expect(state.lastChunkLength == "second chunk".count)

        await state.resendLastRecording()
        #expect(state.recordingStatus == .idle)
        // The failed re-transcription restores the pre-resend document and
        // the chunk boundary, so the next resend still replaces the tail.
        #expect(state.transcript == "first chunk\nsecond chunk")
        #expect(state.lastChunkLength == "second chunk".count)
        #expect(state.chunkInFlight == false)
    }

    @Test func resendInAppendModeWithoutChunkBoundaryAppendsAtEnd() async throws {
        resetTranscriptionStrategyDefault()
        defer { resetTranscriptionStrategyDefault() }
        let keychain = InMemoryKeychainStore()
        let recorder = MockAudioRecorder()
        let (client, mock) = makeStubVoiceFlowClient(
            liveResult: .success("second chunk"),
            bulkResult: .success("second chunk fixed")
        )
        let state = AppState(
            keychainStore: keychain,
            audioRecorder: recorder,
            voiceFlowClient: client,
            clipboardWriter: MockClipboardWriter()
        )

        state.saveAIBuilderToken("fake-token")
        state.transcriptMode = .append
        state.transcript = "first chunk"
        await state.startRecording()
        await state.stopRecording()
        #expect(state.transcript == "first chunk\nsecond chunk")

        // The user edited the document after the merge: the chunk boundary
        // is gone, so a resend appends at the end instead of clobbering.
        state.transcript = "first chunk (edited)\nsecond chunk"
        #expect(state.lastChunkLength == nil)

        await mock.setBulkResult(.success("second chunk fixed"))
        await state.resendLastRecording()
        #expect(state.transcript == "first chunk (edited)\nsecond chunk\nsecond chunk fixed")
    }

    @Test func failedEmptyChunkDoesNotStealOldChunkBoundaryOnResend() async throws {
        resetTranscriptionStrategyDefault()
        defer { resetTranscriptionStrategyDefault() }
        let keychain = InMemoryKeychainStore()
        let recorder = MockAudioRecorder()
        let (client, mock) = makeStubVoiceFlowClient(
            liveResult: .success("second chunk"),
            bulkResult: .success("third chunk fixed")
        )
        let state = AppState(
            keychainStore: keychain,
            audioRecorder: recorder,
            voiceFlowClient: client,
            clipboardWriter: MockClipboardWriter()
        )

        state.saveAIBuilderToken("fake-token")
        state.transcriptMode = .append
        state.transcript = "first chunk"
        await state.startRecording()
        await state.stopRecording()
        #expect(state.transcript == "first chunk\nsecond chunk")
        #expect(state.lastChunkLength == "second chunk".count)

        // A new recording whose transcription fails with no visible
        // partial must not leave the old chunk boundary pointing at the
        // new (resendable) audio.
        await mock.setLiveResult(.failure(VoiceFlowError.connectionLost("finalize failed")))
        await state.startRecording()
        await state.stopRecording()
        #expect(state.recordingStatus == .idle)
        #expect(state.transcript == "first chunk\nsecond chunk")
        #expect(state.lastChunkLength == nil)

        // Resending the failed recording appends at the end; it must not
        // replace the previously merged chunk.
        await state.resendLastRecording()
        #expect(state.transcript == "first chunk\nsecond chunk\nthird chunk fixed")
    }

    @Test func replaceSuccessThenAppendResendReplacesWholePage() async throws {
        resetTranscriptionStrategyDefault()
        defer { resetTranscriptionStrategyDefault() }
        let keychain = InMemoryKeychainStore()
        let recorder = MockAudioRecorder()
        let (client, mock) = makeStubVoiceFlowClient(
            liveResult: .success("replace result"),
            bulkResult: .success("replace result fixed")
        )
        let state = AppState(
            keychainStore: keychain,
            audioRecorder: recorder,
            voiceFlowClient: client,
            clipboardWriter: MockClipboardWriter()
        )

        state.saveAIBuilderToken("fake-token")
        state.transcriptMode = .replace
        await state.startRecording()
        await state.stopRecording()
        #expect(state.transcript == "replace result")
        #expect(state.lastChunkLength == "replace result".count)

        // Switching to append after a replace merge: resending the same
        // recording replaces the whole page instead of composing below it.
        state.transcriptMode = .append
        await mock.setBulkResult(.success("replace result fixed"))
        await state.resendLastRecording()
        #expect(state.transcript == "replace result fixed")
        #expect(state.lastChunkLength == "replace result fixed".count)
    }

    @Test func failedSettleKeepsBoundaryWhenBaseEndsInNewline() {
        let state = AppState(keychainStore: InMemoryKeychainStore())
        state.transcriptMode = .append
        state.transcript = "A\n"
        state.composeBase = "A\n"
        state.chunkInFlight = true
        // The base ends in a newline, so composition inserted no separator:
        // the chunk's leading newline is content, not a separator.
        state.applyStreamedTranscript("\nB")
        #expect(state.transcript == "A\n\nB")

        state.settleFailedChunk()
        #expect(state.lastChunkLength == "\nB".count)

        // Resend replaces exactly that chunk, separator and all.
        state.composeBase = state.resendComposeBase()
        #expect(state.composeBase == "A\n")
        state.chunkInFlight = true
        state.applyStreamedTranscript("B fixed")
        #expect(state.transcript == "A\nB fixed")
    }

    // MARK: - Trash button + empty-view restore

    @Test func trashArchivesTranscriptAndLeftChevronRestores() async throws {
        let state = AppState(keychainStore: InMemoryKeychainStore())
        state.transcriptHistory.add("older document")
        state.transcript = "current document"
        #expect(state.canClearTranscript == true)

        state.clearTranscriptToHistory()
        #expect(state.transcript.isEmpty)
        #expect(state.transcriptHistory.currentEntry == "current document")
        #expect(state.canClearTranscript == false)

        // Empty-view restore: the left chevron brings back the just-
        // archived entry instead of stepping further into the past.
        #expect(state.canNavigatePreviousTranscript == true)
        state.navigatePreviousTranscript()
        #expect(state.transcript == "current document")

        // Further back is the older entry, and the right chevron returns.
        #expect(state.canNavigatePreviousTranscript == true)
        state.navigatePreviousTranscript()
        #expect(state.transcript == "older document")
        #expect(state.canNavigateNextTranscript == true)
        state.navigateNextTranscript()
        #expect(state.transcript == "current document")
    }

    @Test func trashRestoresDocumentVerbatim() async throws {
        let state = AppState(keychainStore: InMemoryKeychainStore())
        // History is the undo target, so a restored document must be
        // byte-identical — trailing newlines included.
        state.transcript = "document text\n"
        state.clearTranscriptToHistory()
        #expect(state.transcript.isEmpty)
        state.navigatePreviousTranscript()
        #expect(state.transcript == "document text\n")
    }

    @Test func manualClearAlsoRestoresViaLeftChevron() async throws {
        let state = AppState(keychainStore: InMemoryKeychainStore())
        state.transcriptHistory.add("recent text")
        state.transcript = "recent text"
        // A select-all delete is not the trash button, but the restore
        // rule covers it too.
        state.transcript = ""
        #expect(state.canNavigatePreviousTranscript == true)
        state.navigatePreviousTranscript()
        #expect(state.transcript == "recent text")
    }

    @Test func leftChevronDisabledWhenHistoryEmpty() {
        let state = AppState(keychainStore: InMemoryKeychainStore())
        state.transcript = ""
        #expect(state.canNavigatePreviousTranscript == false)
        state.navigatePreviousTranscript()
        #expect(state.transcript.isEmpty)
    }

    @Test func trashDisabledDuringRecordingAndCustomAction() async throws {
        let state = AppState(keychainStore: InMemoryKeychainStore())
        state.transcript = "document"
        #expect(state.canClearTranscript == true)

        state.recordingStatus = .recording
        #expect(state.canClearTranscript == false)
        #expect(state.canChangeTranscriptMode == false)

        state.recordingStatus = .ready
        state.customActionState = .running(id: UUID(), actionName: "Summarize")
        #expect(state.canClearTranscript == false)
        #expect(state.canChangeTranscriptMode == false)
    }
}
