import Foundation
import VoiceFlowKit

/// Diagnostic helpers used throughout AppState. `recordDiagnostic` is the
/// single entry point all event-emitting code calls; the others format
/// metadata in a privacy-safe way (no tokens, no transcript text) so
/// downstream sinks (OSLog, in-memory test capture) can be inspected
/// freely.
extension AppState {
    func recordDiagnostic(_ name: String, metadata: [String: String] = [:]) {
        diagnostics.record(RecordingDiagnosticEvent(name, metadata: metadata))
    }

    func diagnosticMetadata(for error: Error) -> [String: String] {
        DiagnosticErrorMetadata.metadata(for: error)
    }

    func userFacingErrorDetail(for error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription,
           !description.isEmpty {
            return description
        }
        let description = error.localizedDescription
        return description.isEmpty ? String(describing: error) : description
    }

    func audioFileMetadata(for url: URL) -> [String: String] {
        let byteCount = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
        return ["byteCount": byteCount.map(String.init) ?? "unknown"]
    }

    /// Classify a transcription failure into one of two diagnostic event
    /// names so error rates can be split by upload vs response shape.
    func transcriptionFailureEventName(for error: Error) -> String {
        if let transcriptionError = error as? AIBuilderTranscriptionError {
            switch transcriptionError {
            case .invalidBaseURL, .requestFailed:
                return "transcription_upload_failed"
            case .invalidResponse, .emptyTranscript:
                return "transcription_response_failed"
            }
        }
        if let kitError = error as? VoiceFlowError {
            switch kitError {
            case .invalidEndpoint, .missingToken, .connectionLost, .sessionUnavailable, .httpError:
                return "transcription_upload_failed"
            case .websocketError, .emptyTranscript, .audioConversionFailed, .microphoneUnavailable, .underlying:
                return "transcription_response_failed"
            }
        }
        if error is DecodingError {
            return "transcription_response_failed"
        }
        return "transcription_upload_failed"
    }
}
