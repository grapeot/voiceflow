import Foundation
import Testing
@testable import VoiceFlow

@Suite(.serialized)
struct RealtimeTranscriptionTests {
    @Test func transcriptDeltaReducerAppendsByDefault() {
        let result = TranscriptDeltaReducer.apply(current: "hello", content: " world", isNewResponse: false)
        #expect(result == "hello world")
    }

    @Test func transcriptDeltaReducerReplacesWhenNewResponse() {
        let result = TranscriptDeltaReducer.apply(current: "old text", content: "fresh start", isNewResponse: true)
        #expect(result == "fresh start")
    }

    @Test func audioChunkEncoderEmitsFixedSizeChunks() {
        var encoder = AudioChunkEncoder(chunkByteSize: 4)
        let chunks = encoder.append(Data([1, 2, 3, 4, 5, 6, 7]))
        #expect(chunks.count == 1)
        #expect(chunks[0] == Data([1, 2, 3, 4]))
        #expect(encoder.pending == Data([5, 6, 7]))
    }

    @Test func audioChunkEncoderFlushRemainderClearsPending() {
        var encoder = AudioChunkEncoder(chunkByteSize: 8)
        _ = encoder.append(Data([1, 2, 3]))
        let remainder = encoder.flushRemainder()
        #expect(remainder == Data([1, 2, 3]))
        #expect(encoder.pending.isEmpty)
    }

    @Test func messageParserHandlesStatusTextAndError() throws {
        let status = try RealtimeMessageParser.parse(data: Data("{\"type\":\"status\",\"status\":\"generating\"}".utf8))
        #expect(status == .status(.generating))

        let text = try RealtimeMessageParser.parse(data: Data("{\"type\":\"text\",\"content\":\"hi\",\"isNewResponse\":true}".utf8))
        #expect(text == .textDelta(content: "hi", isNewResponse: true))

        let error = try RealtimeMessageParser.parse(data: Data("{\"type\":\"error\",\"content\":\"bad token\"}".utf8))
        #expect(error == .error(message: "bad token"))
    }

    @Test func websocketURLBuilderUsesHostAndFixedPath() throws {
        let url = try RealtimeWebSocketURLBuilder.websocketURL(from: "https://space.ai-builders.com/backend")
        #expect(url.absoluteString == "wss://space.ai-builders.com/api/v1/ws")
    }

    @Test func pcmWAVWriterRoundTripsPCMData() throws {
        let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent("voiceflow-pcm-roundtrip.wav")
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let pcm = Data([0, 1, 2, 3, 4, 5])
        try PCM16WAVWriter.write(pcmData: pcm, to: sourceURL)
        let decoded = try PCM16WAVWriter.readPCM(from: sourceURL)
        #expect(decoded == pcm)
    }

    @Test func mockLiveSessionStreamsTranscriptAndFinalize() async throws {
        let client = MockRealtimeTranscriptionClient(liveResult: .success("streamed words"))
        var events: [RealtimeTranscriptEvent] = []
        let session = try await client.beginLiveSession(
            baseURL: "https://space.ai-builders.com/backend",
            token: "token",
            model: "gpt-realtime",
            onEvent: { events.append($0) }
        )

        await session.appendAudioChunk(Data(repeating: 0, count: 100))
        try await session.finalize(onPartialTranscript: nil)
        await session.cancel()

        #expect(events.contains(.status(.connected)))
        #expect(events.contains(.textDelta(content: "streamed words", isNewResponse: true)))
        #expect(events.contains(.status(.idle)))
    }
}
