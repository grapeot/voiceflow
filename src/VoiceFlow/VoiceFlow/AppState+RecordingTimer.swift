import Foundation

/// Recording elapsed-time timer: drives `recordingTimerText` once per
/// second while a session is active. Uses `Timer` (not Combine / Task)
/// because the UI only needs second-level granularity and we want the
/// timer to coalesce naturally with the run loop.
extension AppState {
    func resetRecordingTimer() {
        stopRecordingTimer()
        recordingTimerText = RecordingTimerFormatter.format(elapsedSeconds: 0)
    }

    func startRecordingTimer() {
        recordingTimerStartDate = Date()
        recordingTimerText = RecordingTimerFormatter.format(elapsedSeconds: 0)
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.updateRecordingTimerText()
            }
        }
    }

    func stopRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingTimerStartDate = nil
    }

    private func updateRecordingTimerText() {
        guard let recordingTimerStartDate else { return }
        let elapsed = Int(Date().timeIntervalSince(recordingTimerStartDate))
        recordingTimerText = RecordingTimerFormatter.format(elapsedSeconds: elapsed)
    }
}
