import Foundation

/// Transcript clipboard + history navigation. `transcript` is the live
/// editable text in `RecordView`; `transcriptHistory` is a bounded
/// queue of past transcripts that the user can step through.
extension AppState {
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
        guard canNavigateTranscriptHistory else { return }
        // Empty-view restore: the transcript area was cleared (trash button
        // or a manual select-all delete). Bring back the entry the cursor is
        // currently at instead of stepping further into the past.
        if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let currentText = transcriptHistory.currentEntry {
            transcript = currentText
            openCodeSendStatus = .idle
            lastClipboardStatusKey = nil
            return
        }
        guard let previousText = transcriptHistory.navigatePrevious() else { return }
        transcript = previousText
        openCodeSendStatus = .idle
        lastClipboardStatusKey = nil
    }

    /// Trash button: archive the current transcript into history and clear
    /// the transcript area. Available in both modes; the left chevron
    /// restores the just-archived entry (empty-view restore rule), so no
    /// confirmation dialog is needed.
    func clearTranscriptToHistory() {
        guard canClearTranscript else { return }
        transcriptHistory.add(transcript)
        transcript = ""
        openCodeSendStatus = .idle
        lastClipboardStatusKey = nil
        recordDiagnostic("transcript_cleared_to_history", metadata: ["characterCount": "\(transcriptHistory.currentEntry?.count ?? 0)"])
    }

    func navigateNextTranscript() {
        guard canNavigateTranscriptHistory else { return }
        guard let nextText = transcriptHistory.navigateNext() else { return }
        transcript = nextText
        openCodeSendStatus = .idle
        lastClipboardStatusKey = nil
    }
}
