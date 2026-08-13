import Foundation

/// Custom Action behavior: run / cancel / retry the single user-defined
/// text transformation. State (`customActionConfig`, `customActionState`)
/// lives on the main `AppState` since SwiftUI views bind to it directly;
/// behavior is grouped here.
///
/// Ownership: each run gets a fresh UUID. Every completion path checks the
/// id before writing transcript / history / clipboard, so a late or
/// cancelled response cannot overwrite text the user changed after tapping.
/// UI disablement is not enough — `startRecording`, history navigation,
/// Resend, and token clearing all guard internally too.
extension AppState {
    var canRunCustomAction: Bool {
        canCopyTranscript
            && hasSavedAIBuilderToken
            && customActionConfig.isConfigured
            && !customActionState.isRunning
            && canNavigateTranscriptHistory
    }

    var canCancelCustomAction: Bool {
        customActionState.isRunning
    }

    var customActionDisplayLabel: String {
        let name = customActionConfig.trimmedActionName
        if name.isEmpty { return customActionConfig.actionName }
        return name
    }

    /// Snapshot + dispatch. The source transcript, instructions, and model
    /// are captured at request start; settings changes during the request do
    /// not affect it. The token is read fresh from Keychain for each
    /// attempt and is never stored in retry state.
    func runCustomAction() {
        guard canRunCustomAction else { return }
        guard let token = try? keychainStore.readString(for: Self.tokenKey), !token.isEmpty else {
            customActionState = .failed(messageKey: "record.customAction.error.missingToken")
            return
        }
        let source = transcript
        let instructions = customActionConfig.trimmedInstructions
        let actionName = customActionDisplayLabel
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let id = UUID()
        customActionSourceSnapshot = source
        customActionState = .running(id: id, actionName: actionName)
        recordDiagnostic("custom_action_started", metadata: [
            "characterCount": "\(source.count)",
            "actionName": actionName
        ])

        customActionTask?.cancel()
        customActionTask = Task { [weak self, id] in
            await self?.performCustomActionRequest(
                id: id,
                source: source,
                instructions: instructions,
                token: token,
                actionName: actionName
            )
        }
    }

    func cancelCustomAction() {
        guard customActionState.isRunning else { return }
        // Revoke write ownership first, then cancel the network task. A late
        // success cannot commit because the id no longer matches.
        customActionState = .idle
        customActionSourceSnapshot = nil
        customActionTask?.cancel()
        customActionTask = nil
        recordDiagnostic("custom_action_cancelled", metadata: [:])
    }

    func clearCustomActionFailure() {
        if case .failed = customActionState {
            customActionState = .idle
        }
    }

    private func performCustomActionRequest(
        id: UUID,
        source: String,
        instructions: String,
        token: String,
        actionName: String
    ) async {
        do {
            let result = try await customActionClient.transform(
                transcript: source,
                instructions: instructions,
                baseURL: aiBuilderEndpoint,
                token: token
            )
            await commitCustomActionSuccess(id: id, result: result, actionName: actionName)
        } catch is CancellationError {
            // Cancellation is handled by cancelCustomAction (ownership
            // already revoked). If the task was cancelled without going
            // through cancel (e.g. view teardown), still clear to idle if we
            // still own it.
            await MainActor.run {
                if case .running(let runningID, _) = self.customActionState, runningID == id {
                    self.customActionState = .idle
                    self.customActionSourceSnapshot = nil
                }
            }
        } catch {
            await commitCustomActionFailure(id: id, error: error, actionName: actionName)
        }
    }

    private func commitCustomActionSuccess(id: UUID, result: String, actionName: String) {
        guard case .running(let runningID, _) = customActionState, runningID == id else { return }
        guard let source = customActionSourceSnapshot else { return }

        // 1. Preserve source + result in history (result newest, source next).
        transcriptHistory.addTransform(result: result, source: source)
        // 2. Replace the editor with the result.
        transcript = result
        // 3. Copy the result to the clipboard (failure does not roll back).
        do {
            try clipboardWriter.write(result)
            lastClipboardStatusKey = "record.clipboard.copied"
            recordDiagnostic("custom_action_succeeded", metadata: [
                "characterCount": "\(result.count)",
                "actionName": actionName
            ])
        } catch {
            lastClipboardStatusKey = "record.clipboard.failed"
            recordDiagnostic("custom_action_succeeded_clipboard_failed", metadata: [
                "characterCount": "\(result.count)",
                "actionName": actionName
            ])
        }
        customActionState = .idle
        customActionSourceSnapshot = nil
        customActionTask = nil
    }

    private func commitCustomActionFailure(id: UUID, error: Error, actionName: String) {
        guard case .running(let runningID, _) = customActionState, runningID == id else { return }
        // Do not touch transcript / history / clipboard on failure.
        let messageKey = userFacingCustomActionErrorKey(for: error)
        customActionState = .failed(messageKey: messageKey)
        customActionSourceSnapshot = nil
        customActionTask = nil
        recordDiagnostic("custom_action_failed", metadata: [
            "actionName": actionName,
            "error": String(describing: error)
        ])
    }

    private func userFacingCustomActionErrorKey(for error: Error) -> String {
        if let clientError = error as? CustomActionClientError {
            switch clientError {
            case .requestFailed(let statusCode):
                switch statusCode {
                case 401: return "record.customAction.error.unauthorized"
                case 403: return "record.customAction.error.forbidden"
                case 429: return "record.customAction.error.rateLimited"
                case 500..<600: return "record.customAction.error.serverError"
                default: return "record.customAction.error.requestFailed"
                }
            case .invalidBaseURL, .invalidResponse:
                return "record.customAction.error.invalidResponse"
            case .emptyContent, .nonTextContent:
                return "record.customAction.error.emptyResult"
            case .truncated:
                return "record.customAction.error.truncated"
            }
        }
        if error is URLError {
            return "record.customAction.error.network"
        }
        return "record.customAction.error.generic"
    }
}