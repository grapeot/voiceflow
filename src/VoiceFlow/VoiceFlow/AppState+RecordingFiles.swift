import Foundation

/// Recording file persistence: save the last recording to Application
/// Support (so resend can re-run bulk transcription on the original audio)
/// and export a copy to Documents (so the user can find it in Files).
extension AppState {
    func saveCurrentRecording() {
        guard canSaveRecording, let sourceURL = lastRecordingURL else { return }

        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let destinationURL = RecordingFileSaver.makeDestinationURL(
            in: documentsPath,
            fileExtension: sourceURL.pathExtension
        )

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

    /// Copy a freshly captured temp file to Application Support / VoiceFlow,
    /// replacing the prior recording so resend always reads the
    /// most recent capture.
    func persistLastRecording(from temporaryURL: URL) throws -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceFlow", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileExtension = temporaryURL.pathExtension.isEmpty ? "wav" : temporaryURL.pathExtension
        let destinationURL = directory
            .appendingPathComponent("last-recording")
            .appendingPathExtension(fileExtension)
        for staleExtension in ["wav", "m4a"] where staleExtension != fileExtension {
            try? FileManager.default.removeItem(
                at: directory.appendingPathComponent("last-recording").appendingPathExtension(staleExtension)
            )
        }
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.copyItem(at: temporaryURL, to: destinationURL)
        return destinationURL
    }
}
