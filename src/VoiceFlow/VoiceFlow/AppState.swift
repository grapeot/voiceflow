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
    @Published var connectionStatus: ConnectionStatus = .untested

    let aiBuilderEndpoint = "https://space.ai-builders.com/backend"
    private let keychainStore: KeychainStoring
    private let aiBuilderClient: AIBuilderConnectionTesting
    private let tokenKey = "aiBuilderToken"

    init(
        keychainStore: KeychainStoring? = nil,
        aiBuilderClient: AIBuilderConnectionTesting? = nil
    ) {
        let isUITestMode = ProcessInfo.processInfo.arguments.contains("-uiTestMode")
        self.keychainStore = keychainStore ?? (isUITestMode ? InMemoryKeychainStore() : KeychainStore())
        if let aiBuilderClient {
            self.aiBuilderClient = aiBuilderClient
        } else if isUITestMode {
            self.aiBuilderClient = MockAIBuilderConnectionClient(result: .success(()))
        } else {
            self.aiBuilderClient = AIBuilderClient()
        }
        self.hasSavedAIBuilderToken = (try? self.keychainStore.readString(for: tokenKey)) != nil
    }

    var canCopyTranscript: Bool {
        !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canSendToOpenCode: Bool {
        canCopyTranscript && isOpenCodeConfigured
    }

    var tokenDisplayValue: String {
        hasSavedAIBuilderToken ? "••••••••" : ""
    }

    func saveAIBuilderToken(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try keychainStore.saveString(trimmed, for: tokenKey)
            hasSavedAIBuilderToken = true
            connectionStatus = .untested
        } catch {
            connectionStatus = .failed(String(localized: "settings.connection.saveFailed"))
        }
    }

    func clearAIBuilderToken() {
        do {
            try keychainStore.deleteString(for: tokenKey)
        } catch {
            connectionStatus = .failed(String(localized: "settings.connection.clearFailed"))
            return
        }
        hasSavedAIBuilderToken = false
        connectionStatus = .untested
    }

    func testAIBuilderConnection() async {
        guard let token = try? keychainStore.readString(for: tokenKey), !token.isEmpty else {
            connectionStatus = .failed(String(localized: "settings.connection.missingToken"))
            return
        }

        connectionStatus = .testing
        do {
            try await aiBuilderClient.testConnection(baseURL: aiBuilderEndpoint, token: token)
            connectionStatus = .success
        } catch {
            connectionStatus = .failed(String(localized: "settings.connection.failed"))
        }
    }
}
