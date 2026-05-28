import Foundation

/// Public error model exposed by `VoiceFlowClient` / `VoiceFlowSession` /
/// `VoiceFlowMicrophone`. Internal `RealtimeTranscriptionError` and the
/// other typed errors are translated into this enum at the facade
/// boundary so external callers don't depend on internal types.
public enum VoiceFlowError: Error, Sendable, Equatable {
    case invalidEndpoint
    case missingToken
    case httpError(statusCode: Int)
    case sessionUnavailable
    case websocketError(String)
    case connectionLost(String)
    case audioConversionFailed
    case emptyTranscript
    case microphoneUnavailable
    case underlying(String)
}

extension VoiceFlowError {
    /// Translate an internal `RealtimeTranscriptionError` into the public
    /// error model. Internal errors keep their structure for kit logic;
    /// the public surface only carries what hosts need to switch on.
    init(_ realtime: RealtimeTranscriptionError) {
        switch realtime {
        case .invalidBaseURL:
            self = .invalidEndpoint
        case .missingToken:
            self = .missingToken
        case .invalidMessage:
            self = .websocketError("Invalid server message")
        case .connectionLost(let detail):
            self = .connectionLost(detail)
        case .websocketError(let detail):
            self = .websocketError(detail)
        case .sessionUnavailable:
            self = .sessionUnavailable
        case .emptyTranscript:
            self = .emptyTranscript
        case .audioConversionFailed:
            self = .audioConversionFailed
        case .httpError(let statusCode):
            self = .httpError(statusCode: statusCode)
        }
    }
}
