import Foundation
import OSLog

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
