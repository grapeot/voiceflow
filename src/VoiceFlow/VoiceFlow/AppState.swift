import Combine
import Foundation

@MainActor
final class AppState: ObservableObject {
    enum RecordingStatus: Equatable {
        case idle
        case recording
        case transcribing
        case ready
    }

    @Published var recordingStatus: RecordingStatus = .idle
    @Published var transcript: String = ""
    @Published var hasSavedAIBuilderToken = false
    @Published var isOpenCodeConfigured = false
    @Published var lastClipboardStatus: String?

    let aiBuilderEndpoint = "https://space.ai-builders.com/backend"

    var canCopyTranscript: Bool {
        !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canSendToOpenCode: Bool {
        canCopyTranscript && isOpenCodeConfigured
    }
}
