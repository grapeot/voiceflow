import Foundation

enum RecordingTimerFormatter {
    static func format(elapsedSeconds: Int) -> String {
        let minutes = max(elapsedSeconds, 0) / 60
        let seconds = max(elapsedSeconds, 0) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
