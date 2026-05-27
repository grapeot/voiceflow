import Foundation

enum RealtimeServerStatus: String, Equatable, Sendable {
    case idle
    case connecting
    case connected
    case generating
}

enum RealtimeTranscriptEvent: Equatable, Sendable {
    case status(RealtimeServerStatus)
    case textDelta(content: String, isNewResponse: Bool)
    case error(message: String)
    case disconnected
}

enum RealtimeConnectionPhase: Equatable, Sendable, Hashable {
    case disconnected
    case connecting
    case connected
    case generating
    case recovering
}

enum RealtimeTranscriptionError: Error, Equatable {
    case invalidBaseURL
    case missingToken
    case invalidMessage
    case connectionLost(String)
    case websocketError(String)
    case sessionUnavailable
    case emptyTranscript
    case audioConversionFailed
}

enum RealtimeTranscriptionConfig: Sendable {
    nonisolated static let defaultModel = "gpt-realtime"
    nonisolated static let sampleRate: Double = 48_000
    nonisolated static let chunkDurationSeconds: Double = 0.5
    nonisolated static let replayChunkSize = 48_000
    nonisolated static let heartbeatIntervalSeconds: UInt64 = 30
    nonisolated static let websocketPath = "/api/v1/ws"

    nonisolated static var chunkByteSize: Int {
        Int(sampleRate * chunkDurationSeconds) * 2
    }
}

enum RealtimeMessageParser: Sendable {
    nonisolated static func parse(data: Data) throws -> RealtimeTranscriptEvent {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let json = object as? [String: Any],
              let type = json["type"] as? String else {
            throw RealtimeTranscriptionError.invalidMessage
        }

        switch type {
        case "status":
            guard let statusRaw = json["status"] as? String,
                  let status = RealtimeServerStatus(rawValue: statusRaw) else {
                throw RealtimeTranscriptionError.invalidMessage
            }
            return .status(status)
        case "text":
            let content = json["content"] as? String ?? ""
            let isNewResponse = json["isNewResponse"] as? Bool ?? false
            return .textDelta(content: content, isNewResponse: isNewResponse)
        case "error":
            let message = json["content"] as? String
                ?? json["message"] as? String
                ?? "Unknown websocket error"
            return .error(message: message)
        default:
            throw RealtimeTranscriptionError.invalidMessage
        }
    }

    nonisolated static func parseMessage(_ message: URLSessionWebSocketTask.Message) throws -> RealtimeTranscriptEvent {
        switch message {
        case .data(let data):
            return try parse(data: data)
        case .string(let string):
            guard let data = string.data(using: .utf8) else {
                throw RealtimeTranscriptionError.invalidMessage
            }
            return try parse(data: data)
        @unknown default:
            throw RealtimeTranscriptionError.invalidMessage
        }
    }

    nonisolated static func startRecordingMessage(model: String) throws -> String {
        let payload: [String: Any] = [
            "type": "start_recording",
            "model": model
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let string = String(data: data, encoding: .utf8) else {
            throw RealtimeTranscriptionError.invalidMessage
        }
        return string
    }

    nonisolated static let stopRecordingMessage = "{\"type\":\"stop_recording\"}"
    nonisolated static let statusRequestMessage = "{\"type\":\"status_request\"}"
}

enum TranscriptDeltaReducer: Sendable {
    nonisolated static func apply(current: String, content: String, isNewResponse: Bool) -> String {
        if isNewResponse {
            return content
        }
        return current + content
    }
}

enum RealtimeWebSocketURLBuilder: Sendable {
    nonisolated static func websocketURL(from baseURL: String) throws -> URL {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let base = URL(string: trimmed),
              let host = base.host else {
            throw RealtimeTranscriptionError.invalidBaseURL
        }

        var components = URLComponents()
        components.scheme = "wss"
        components.host = host
        components.path = RealtimeTranscriptionConfig.websocketPath
        guard let url = components.url else {
            throw RealtimeTranscriptionError.invalidBaseURL
        }
        return url
    }
}

enum PCM16WAVWriter: Sendable {
    nonisolated static func write(pcmData: Data, sampleRate: UInt32 = 48_000, to url: URL) throws {
        guard !pcmData.isEmpty else {
            throw RealtimeTranscriptionError.audioConversionFailed
        }

        let byteRate = sampleRate * 2
        var header = Data()
        header.appendUTF8("RIFF")
        header.appendUInt32LE(36 + UInt32(pcmData.count))
        header.appendUTF8("WAVE")
        header.appendUTF8("fmt ")
        header.appendUInt32LE(16)
        header.appendUInt16LE(1)
        header.appendUInt16LE(1)
        header.appendUInt32LE(sampleRate)
        header.appendUInt32LE(byteRate)
        header.appendUInt16LE(2)
        header.appendUInt16LE(16)
        header.appendUTF8("data")
        header.appendUInt32LE(UInt32(pcmData.count))

        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        FileManager.default.createFile(atPath: url.path, contents: header + pcmData)
    }

    nonisolated static func readPCM(from wavURL: URL) throws -> Data {
        let data = try Data(contentsOf: wavURL)
        guard data.count > 44 else {
            throw RealtimeTranscriptionError.audioConversionFailed
        }
        return data.subdata(in: 44..<data.count)
    }
}

private extension Data {
    mutating func appendUTF8(_ string: String) {
        append(Data(string.utf8))
    }

    mutating func appendUInt16LE(_ value: UInt16) {
        var littleEndian = value.littleEndian
        append(Data(bytes: &littleEndian, count: MemoryLayout<UInt16>.size))
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        var littleEndian = value.littleEndian
        append(Data(bytes: &littleEndian, count: MemoryLayout<UInt32>.size))
    }
}
