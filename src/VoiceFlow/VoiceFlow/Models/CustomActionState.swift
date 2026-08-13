import Foundation

/// State for the single user-defined text transformation. Independent from
/// recording/transcription state so a transform cannot race with a new
/// recording, history navigation, or Resend.
enum CustomActionState: Equatable {
    case idle
    case running(id: UUID, actionName: String)
    case failed(messageKey: String)

    var localizedKey: String? {
        switch self {
        case .idle: nil
        case .running(_, let name):
            // "Running <name>…" — name is interpolated at the call site,
            // not here, so this is intentionally unused. Kept for parity
            // with other status enums.
            nil
        case .failed(let key): key
        }
    }

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}