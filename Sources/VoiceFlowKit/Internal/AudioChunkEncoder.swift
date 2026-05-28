import Foundation

public struct AudioChunkEncoder {
    public private(set) var pending = Data()
    public let chunkByteSize: Int

    public init(chunkByteSize: Int = RealtimeTranscriptionConfig.chunkByteSize) {
        self.chunkByteSize = chunkByteSize
    }

    public mutating func append(_ data: Data) -> [Data] {
        guard !data.isEmpty else { return [] }
        pending.append(data)
        var chunks: [Data] = []
        while pending.count >= chunkByteSize {
            let chunk = pending.prefix(chunkByteSize)
            pending.removeFirst(chunkByteSize)
            chunks.append(Data(chunk))
        }
        return chunks
    }

    public mutating func flushRemainder() -> Data {
        defer { pending.removeAll(keepingCapacity: false) }
        return pending
    }
}

final class AudioChunkCache: @unchecked Sendable {
    nonisolated private let queue = DispatchQueue(label: "com.grapeot.VoiceFlow.audioChunkCache")
    nonisolated let fileURL: URL
    nonisolated(unsafe) private var byteCountValue = 0

    init(directory: URL = FileManager.default.temporaryDirectory) throws {
        fileURL = directory.appendingPathComponent("voiceflow-stream-\(UUID().uuidString).pcm")
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
    }

    nonisolated var byteCount: Int {
        queue.sync { byteCountValue }
    }

    nonisolated func append(_ data: Data) throws {
        guard !data.isEmpty else { return }
        try queue.sync {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            byteCountValue += data.count
        }
    }

    nonisolated func readChunk(offset: Int, maxBytes: Int) throws -> Data {
        try queue.sync {
            guard offset < byteCountValue else { return Data() }
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(offset))
            return try handle.read(upToCount: min(maxBytes, byteCountValue - offset)) ?? Data()
        }
    }

    nonisolated func remove() {
        queue.sync {
            try? FileManager.default.removeItem(at: fileURL)
            byteCountValue = 0
        }
    }
}
