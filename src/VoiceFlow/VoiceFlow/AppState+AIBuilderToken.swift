import Foundation
import VoiceFlowKit

/// AI Builder Space token management: save/clear via Keychain, test the
/// configured token against the backend's usage endpoint. Token persistence
/// is handled by `keychainStore`; UI views observe `hasSavedAIBuilderToken`
/// and `connectionStatus` on the main `AppState`.
extension AppState {
    var tokenDisplayValue: String {
        hasSavedAIBuilderToken ? "••••••••" : ""
    }

    func saveAIBuilderToken(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try keychainStore.saveString(trimmed, for: Self.tokenKey)
            hasSavedAIBuilderToken = true
            connectionStatus = .untested
        } catch {
            connectionStatus = .failed("settings.connection.saveFailed", nil)
        }
    }

    func clearAIBuilderToken() {
        do {
            try keychainStore.deleteString(for: Self.tokenKey)
        } catch {
            connectionStatus = .failed("settings.connection.clearFailed", nil)
            return
        }
        hasSavedAIBuilderToken = false
        connectionStatus = .untested
    }

    func testAIBuilderConnection() async {
        guard let token = try? keychainStore.readString(for: Self.tokenKey), !token.isEmpty else {
            connectionStatus = .failed("settings.connection.missingToken", nil)
            return
        }

        connectionStatus = .testing
        do {
            try await aiBuilderClient.testConnection(baseURL: aiBuilderEndpoint, token: token)
            connectionStatus = .success
        } catch {
            connectionStatus = .failed("settings.connection.failed", userFacingErrorDetail(for: error))
        }
    }
}
