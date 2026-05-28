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
}
