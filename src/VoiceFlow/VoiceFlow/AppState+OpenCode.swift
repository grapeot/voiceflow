import Foundation

/// OpenCode integration: password management, connection testing, transcript
/// send. State (`openCodeServerURL`, `openCodeUsername`, `hasSavedOpenCodePassword`,
/// `openCodeSendStatus`, `openCodeConnectionStatus`) lives on the main `AppState`
/// since SwiftUI views bind to it directly; behavior is grouped here.
extension AppState {
    var canSendToOpenCode: Bool {
        canCopyTranscript && isOpenCodeConfigured && openCodeConnectionStatus == .success
    }

    var isOpenCodeConfigured: Bool {
        hasSavedOpenCodePassword
            && !openCodeServerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !openCodeUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var openCodePasswordDisplayValue: String {
        hasSavedOpenCodePassword ? "••••••••" : ""
    }

    func saveOpenCodePassword(_ password: String) {
        let trimmed = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try keychainStore.saveString(trimmed, for: Self.openCodePasswordKey)
            hasSavedOpenCodePassword = true
            openCodeSendStatus = .idle
            UserDefaults.standard.set(false, forKey: Self.openCodeConnectionVerifiedDefaultsKey)
            openCodeConnectionStatus = .untested
        } catch {
            openCodeSendStatus = .failed("settings.openCode.saveFailed")
        }
    }

    func clearOpenCodePassword() {
        do {
            try keychainStore.deleteString(for: Self.openCodePasswordKey)
        } catch {
            openCodeSendStatus = .failed("settings.openCode.clearFailed")
            return
        }
        hasSavedOpenCodePassword = false
        openCodeSendStatus = .idle
        UserDefaults.standard.set(false, forKey: Self.openCodeConnectionVerifiedDefaultsKey)
        openCodeConnectionStatus = .untested
    }

    func testOpenCodeConnection() async {
        guard isOpenCodeConfigured, let password = try? keychainStore.readString(for: Self.openCodePasswordKey), !password.isEmpty else {
            UserDefaults.standard.set(false, forKey: Self.openCodeConnectionVerifiedDefaultsKey)
            openCodeConnectionStatus = .failed("settings.openCode.connection.missingConfig", nil)
            return
        }

        openCodeConnectionStatus = .testing
        do {
            try await openCodeClient.testConnection(
                serverURL: openCodeServerURL.trimmingCharacters(in: .whitespacesAndNewlines),
                username: openCodeUsername.trimmingCharacters(in: .whitespacesAndNewlines),
                password: password
            )
            UserDefaults.standard.set(true, forKey: Self.openCodeConnectionVerifiedDefaultsKey)
            openCodeConnectionStatus = .success
        } catch {
            UserDefaults.standard.set(false, forKey: Self.openCodeConnectionVerifiedDefaultsKey)
            openCodeConnectionStatus = .failed("settings.openCode.connection.failed", userFacingErrorDetail(for: error))
        }
    }

    func sendTranscriptToOpenCode() async {
        guard canCopyTranscript else { return }
        guard isOpenCodeConfigured, let password = try? keychainStore.readString(for: Self.openCodePasswordKey), !password.isEmpty else {
            recordDiagnostic("opencode_send_failed", metadata: ["reason": "notConfigured"])
            openCodeSendStatus = .failed("record.openCode.error.notConfigured")
            return
        }
        guard openCodeConnectionStatus == .success else {
            recordDiagnostic("opencode_send_failed", metadata: ["reason": "connectionNotVerified"])
            openCodeSendStatus = .failed("record.openCode.error.connectionNotVerified")
            return
        }

        openCodeSendStatus = .sending
        recordDiagnostic("opencode_send_started", metadata: ["characterCount": "\(transcript.count)"])
        do {
            try await openCodeClient.sendTranscript(
                transcript,
                serverURL: openCodeServerURL.trimmingCharacters(in: .whitespacesAndNewlines),
                username: openCodeUsername.trimmingCharacters(in: .whitespacesAndNewlines),
                password: password
            )
            recordDiagnostic("opencode_send_succeeded", metadata: ["characterCount": "\(transcript.count)"])
            openCodeSendStatus = .success
        } catch {
            recordDiagnostic("opencode_send_failed", metadata: diagnosticMetadata(for: error))
            openCodeSendStatus = .failed("record.openCode.error.sendFailed")
        }
    }
}
