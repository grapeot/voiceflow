import Foundation
import OSLog
import VoiceFlowKit

struct RecordingDiagnosticEvent: Equatable {
    let name: String
    let metadata: [String: String]

    init(_ name: String, metadata: [String: String] = [:]) {
        self.name = name
        self.metadata = metadata
    }
}

protocol RecordingDiagnosticsReporting {
    func record(_ event: RecordingDiagnosticEvent)
}

struct OSRecordingDiagnostics: RecordingDiagnosticsReporting {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VoiceFlow", category: "Recording")

    func record(_ event: RecordingDiagnosticEvent) {
        let metadata = event.metadata
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        logger.info("recording_event name=\(event.name, privacy: .public) metadata=\(metadata, privacy: .public)")
    }
}

final class InMemoryRecordingDiagnostics: RecordingDiagnosticsReporting {
    private(set) var events: [RecordingDiagnosticEvent] = []

    func record(_ event: RecordingDiagnosticEvent) {
        events.append(event)
    }
}

enum DiagnosticErrorMetadata {
    static func metadata(for error: Error) -> [String: String] {
        var metadata = ["errorType": String(describing: type(of: error))]

        if let recorderError = error as? AudioRecorderError {
            metadata.merge(recorderError.diagnosticMetadata) { _, new in new }
        }

        let nsError = error as NSError
        if metadata["errorDomain"] == nil {
            metadata["errorDomain"] = nsError.domain
        }
        if metadata["errorCode"] == nil {
            metadata["errorCode"] = String(nsError.code)
        }
        if let fourCC = fourCharCodeString(for: nsError.code) {
            metadata["errorFourCC"] = fourCC
        }

        return metadata
    }

    private static func fourCharCodeString(for code: Int) -> String? {
        guard code > 0xFFFF else { return nil }
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF)
        ]
        guard bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) else { return nil }
        return String(bytes: bytes, encoding: .ascii)
    }
}
