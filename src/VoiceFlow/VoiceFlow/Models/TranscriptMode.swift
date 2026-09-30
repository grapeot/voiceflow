import Foundation

/// How a finished transcription combines with the text already in the
/// transcript area.
///
/// - `replace`: each transcription becomes the whole transcript (the
///   historical default).
/// - `append`: each transcription is composed below the existing text so
///   multiple recordings accumulate into one document.
///
/// Session-scoped by design: the value lives for the current app session
/// and falls back to `.replace` on relaunch. It is intentionally not
/// persisted — switching between the two workflows is expected to happen
/// frequently, so the control is on the Record screen, not in Settings.
enum TranscriptMode: String, CaseIterable, Codable, Sendable {
    case replace
    case append
}
