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
    case recoveryStarted
    case recoveryFailed(message: String)
}

enum RealtimeConnectionPhase: Sendable, Hashable {
    case disconnected
    case connecting
    case connected
    case generating
    case recovering
}

extension RealtimeConnectionPhase: Equatable {
    nonisolated static func == (lhs: RealtimeConnectionPhase, rhs: RealtimeConnectionPhase) -> Bool {
        switch (lhs, rhs) {
        case (.disconnected, .disconnected),
             (.connecting, .connecting),
             (.connected, .connected),
             (.generating, .generating),
             (.recovering, .recovering):
            return true
        default:
            return false
        }
    }
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
    case httpError(statusCode: Int)
}

enum RealtimeTranscriptionConfig: Sendable {
    nonisolated static let defaultModel = "gpt-realtime"
    nonisolated static let sampleRate: Double = 24_000
    nonisolated static let chunkDurationSeconds: Double = 0.5
    nonisolated static let replayChunkSize = 240_000
    nonisolated static let heartbeatIntervalSeconds: UInt64 = 12
    nonisolated static let sessionCreatePath = "/v1/audio/realtime/sessions"
    nonisolated static let commitMessage = "{\"type\":\"commit\"}"
    nonisolated static let stopMessage = "{\"type\":\"stop\"}"
    nonisolated static let maxRecoverAttempts = 5
    nonisolated static let recoverBackoffBaseMilliseconds = 300

    nonisolated static var chunkByteSize: Int {
        Int(sampleRate * chunkDurationSeconds) * 2
    }
}

struct RealtimeSessionCreateResponse: Decodable, Sendable, Equatable {
    let sessionID: String
    let wsURL: String

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case wsURL = "ws_url"
    }
}

struct RealtimeSocketEvent: Sendable, Equatable {
    let type: String
    let text: String?
    let code: String?
    let message: String?

    nonisolated init(data: Data) throws {
        let raw = try JSONSerialization.jsonObject(with: data)
        guard let json = raw as? [String: Any],
              let type = json["type"] as? String else {
            throw RealtimeTranscriptionError.invalidMessage
        }
        self.type = type
        self.text = json["text"] as? String ?? json["content"] as? String
        self.code = json["code"] as? String
        self.message = json["message"] as? String
    }
}

enum RealtimeMessageParser: Sendable {
    nonisolated static func parseSocketEvent(_ event: RealtimeSocketEvent) -> RealtimeTranscriptEvent? {
        switch event.type {
        case "session_ready":
            return .status(.connected)
        case "speech_started", "speech_stopped":
            return .status(.connected)
        case "transcript_delta":
            let content = event.text ?? ""
            guard !content.isEmpty else { return nil }
            return .textDelta(content: content, isNewResponse: false)
        case "transcript_completed":
            let content = event.text ?? ""
            guard !content.isEmpty else { return nil }
            return .textDelta(content: content, isNewResponse: true)
        case "session_stopped":
            return .status(.idle)
        case "error":
            let message = event.message ?? event.code ?? "Unknown websocket error"
            return .error(message: message)
        default:
            return nil
        }
    }

    nonisolated static func parseMessage(_ message: URLSessionWebSocketTask.Message) throws -> RealtimeTranscriptEvent {
        let socketEvent = try parseSocketMessage(message)
        guard let event = parseSocketEvent(socketEvent) else {
            throw RealtimeTranscriptionError.invalidMessage
        }
        return event
    }

    nonisolated static func parseSocketMessage(_ message: URLSessionWebSocketTask.Message) throws -> RealtimeSocketEvent {
        switch message {
        case .data(let data):
            return try RealtimeSocketEvent(data: data)
        case .string(let string):
            guard let data = string.data(using: .utf8) else {
                throw RealtimeTranscriptionError.invalidMessage
            }
            return try RealtimeSocketEvent(data: data)
        @unknown default:
            throw RealtimeTranscriptionError.invalidMessage
        }
    }

    nonisolated static func startControlMessage(
        model: String,
        vad: Bool = true,
        silenceDurationMs: Int = 1200
    ) throws -> String {
        let payload: [String: Any] = [
            "type": "start",
            "model": model,
            "vad": vad,
            "silence_duration_ms": silenceDurationMs
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let string = String(data: data, encoding: .utf8) else {
            throw RealtimeTranscriptionError.invalidMessage
        }
        return string
    }
}

enum TranscriptDeltaReducer: Sendable {
    nonisolated static func apply(current: String, content: String, isNewResponse: Bool) -> String {
        if isNewResponse {
            return content
        }
        return current + content
    }
}

struct TranscriptEpochMerger: Sendable, Equatable {
    private(set) var transcriptSnapshot: String = ""
    private(set) var streamEpoch: Int = 0
    private var epochText: String = ""

    var mergedTranscript: String {
        transcriptSnapshot + epochText
    }

    mutating func reset() {
        transcriptSnapshot = ""
        epochText = ""
        streamEpoch = 0
    }

    mutating func beginRecovery() {
        transcriptSnapshot = mergedTranscript
        epochText = ""
        streamEpoch += 1
    }

    mutating func apply(content: String, isNewResponse: Bool) -> String {
        if isNewResponse {
            epochText = content
        } else {
            epochText += content
        }
        return mergedTranscript
    }
}

enum RealtimeAPIURLBuilder: Sendable {
    nonisolated static func normalizedBaseURL(from rawBaseURL: String) throws -> URL {
        let trimmed = rawBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RealtimeTranscriptionError.invalidBaseURL
        }
        let normalized = trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")
            ? trimmed
            : "https://\(trimmed)"
        guard let url = URL(string: normalized), url.host != nil else {
            throw RealtimeTranscriptionError.invalidBaseURL
        }
        return url
    }

    nonisolated static func buildAPIURL(base: URL, path: String) -> URL? {
        let relPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        var basePath = components?.path ?? ""
        if !basePath.isEmpty, !basePath.hasSuffix("/") {
            basePath += "/"
            components?.path = basePath
        }
        let baseForAppend = components?.url ?? base
        return URL(string: relPath, relativeTo: baseForAppend)?.absoluteURL
    }

    nonisolated static func realtimeWebSocketURL(baseURL: URL, relativePath: String) throws -> URL {
        let websocketPath: String
        if relativePath.hasPrefix("/"),
           let basePath = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)?.path,
           !basePath.isEmpty,
           basePath != "/",
           !relativePath.hasPrefix(basePath + "/") {
            websocketPath = basePath + relativePath
        } else {
            websocketPath = relativePath
        }

        guard let httpURL = URL(string: websocketPath, relativeTo: baseURL)?.absoluteURL else {
            throw RealtimeTranscriptionError.invalidBaseURL
        }
        var components = URLComponents(url: httpURL, resolvingAgainstBaseURL: true)
        if components?.scheme == "https" {
            components?.scheme = "wss"
        } else if components?.scheme == "http" {
            components?.scheme = "ws"
        }
        guard let websocketURL = components?.url else {
            throw RealtimeTranscriptionError.invalidBaseURL
        }
        return websocketURL
    }
}

enum PCM16WAVWriter: Sendable {
    nonisolated static func write(pcmData: Data, sampleRate: UInt32 = 24_000, to url: URL) throws {
        guard !pcmData.isEmpty else {
            throw RealtimeTranscriptionError.audioConversionFailed
        }

        let byteRate = sampleRate * 2
        var header = Data()
        WAVHeaderBuilder.appendUTF8("RIFF", to: &header)
        WAVHeaderBuilder.appendUInt32LE(36 + UInt32(pcmData.count), to: &header)
        WAVHeaderBuilder.appendUTF8("WAVE", to: &header)
        WAVHeaderBuilder.appendUTF8("fmt ", to: &header)
        WAVHeaderBuilder.appendUInt32LE(16, to: &header)
        WAVHeaderBuilder.appendUInt16LE(1, to: &header)
        WAVHeaderBuilder.appendUInt16LE(1, to: &header)
        WAVHeaderBuilder.appendUInt32LE(sampleRate, to: &header)
        WAVHeaderBuilder.appendUInt32LE(byteRate, to: &header)
        WAVHeaderBuilder.appendUInt16LE(2, to: &header)
        WAVHeaderBuilder.appendUInt16LE(16, to: &header)
        WAVHeaderBuilder.appendUTF8("data", to: &header)
        WAVHeaderBuilder.appendUInt32LE(UInt32(pcmData.count), to: &header)

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

private enum WAVHeaderBuilder: Sendable {
    nonisolated static func appendUTF8(_ string: String, to data: inout Data) {
        data.append(Data(string.utf8))
    }

    nonisolated static func appendUInt16LE(_ value: UInt16, to data: inout Data) {
        var littleEndian = value.littleEndian
        data.append(Data(bytes: &littleEndian, count: MemoryLayout<UInt16>.size))
    }

    nonisolated static func appendUInt32LE(_ value: UInt32, to data: inout Data) {
        var littleEndian = value.littleEndian
        data.append(Data(bytes: &littleEndian, count: MemoryLayout<UInt32>.size))
    }
}
