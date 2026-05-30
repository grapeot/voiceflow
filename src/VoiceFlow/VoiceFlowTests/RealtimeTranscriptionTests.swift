import Foundation
import Testing
@testable import VoiceFlowKit
@testable import VoiceFlow

@Suite(.serialized)
struct RealtimeTranscriptionTests {
    @Test func transcriptEpochMergerPreservesSnapshotAfterRecovery() {
        var merger = TranscriptEpochMerger()
        _ = merger.apply(content: "hello ", isNewResponse: true)
        _ = merger.apply(content: "world", isNewResponse: false)
        #expect(merger.mergedTranscript == "hello world")
        #expect(merger.streamEpoch == 0)

        merger.beginRecovery()
        #expect(merger.transcriptSnapshot == "hello world")
        #expect(merger.streamEpoch == 1)

        let afterNewResponse = merger.apply(content: "again", isNewResponse: true)
        #expect(afterNewResponse == "hello worldagain")
    }

    @Test func transcriptEpochMergerAppendsWithinEpochAfterRecovery() {
        var merger = TranscriptEpochMerger()
        _ = merger.apply(content: "prefix", isNewResponse: true)
        merger.beginRecovery()
        _ = merger.apply(content: "part1", isNewResponse: true)
        let merged = merger.apply(content: " part2", isNewResponse: false)
        #expect(merged == "prefixpart1 part2")
    }

    @Test func transcriptEpochMergerResetClearsSnapshotAndEpoch() {
        var merger = TranscriptEpochMerger()
        _ = merger.apply(content: "text", isNewResponse: true)
        merger.beginRecovery()
        merger.reset()
        #expect(merger.mergedTranscript.isEmpty)
        #expect(merger.streamEpoch == 0)
        #expect(merger.transcriptSnapshot.isEmpty)
    }

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

    @Test func messageParserHandlesSessionReadyTranscriptAndError() throws {
        let ready = try RealtimeMessageParser.parseSocketEvent(
            RealtimeSocketEvent(data: Data("{\"type\":\"session_ready\",\"session_id\":\"s1\"}".utf8))
        )
        #expect(ready == .status(.connected))

        let delta = try RealtimeMessageParser.parseSocketEvent(
            RealtimeSocketEvent(data: Data("{\"type\":\"transcript_delta\",\"text\":\"hi\"}".utf8))
        )
        #expect(delta == .textDelta(content: "hi", isNewResponse: false))

        let completed = try RealtimeMessageParser.parseSocketEvent(
            RealtimeSocketEvent(data: Data("{\"type\":\"transcript_completed\",\"text\":\"done\"}".utf8))
        )
        #expect(completed == .textDelta(content: "done", isNewResponse: true))

        let error = try RealtimeMessageParser.parseSocketEvent(
            RealtimeSocketEvent(data: Data("{\"type\":\"error\",\"message\":\"bad token\"}".utf8))
        )
        #expect(error == .error(message: "bad token"))
    }

    @Test func realtimeWebSocketURLPreservesBackendMountPath() throws {
        let base = try RealtimeAPIURLBuilder.normalizedBaseURL(from: "https://space.ai-builders.com/backend")
        let url = try RealtimeAPIURLBuilder.realtimeWebSocketURL(
            baseURL: base,
            relativePath: "/backend/v1/audio/realtime/ws?ticket=test"
        )
        #expect(url.scheme == "wss")
        #expect(url.host == "space.ai-builders.com")
        #expect(url.path == "/backend/v1/audio/realtime/ws")
        #expect(url.query == "ticket=test")
    }

    @Test func pcmWAVWriterRoundTripsPCMData() throws {
        let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent("voiceflow-pcm-roundtrip.wav")
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let pcm = Data([0, 1, 2, 3, 4, 5])
        try PCM16WAVWriter.write(pcmData: pcm, to: sourceURL)
        let decoded = try PCM16WAVWriter.readPCM(from: sourceURL)
        #expect(decoded == pcm)
    }

    @Test func recoverableBufferTooSmallErrorDetection() {
        #expect(
            RealtimeTranscriptionSupport.isRecoverableBufferTooSmallError(
                "Error committing input audio buffer: buffer too small. Expected at least 100ms"
            )
        )
        #expect(!RealtimeTranscriptionSupport.isRecoverableBufferTooSmallError("bad token"))
    }

    @Test func minCommitAudioBytesMatches100msAt24kHz() {
        #expect(RealtimeTranscriptionConfig.minCommitAudioBytes == 4_800)
    }

    @Test func resolveFinalizeTranscriptPrefersLongerPartialOverShorterCompleted() {
        let partial = "The first sentence. The second sentence."
        let completed = "The second sentence."
        #expect(
            RealtimeTranscriptionSupport.resolveFinalizeTranscript(partial: partial, completed: completed)
            == partial
        )
    }

    @Test func resolveFinalizeTranscriptAppendSemanticsPreserveFullText() {
        var partial = ""
        partial += "Hello "
        partial += "world"
        let resolved = RealtimeTranscriptionSupport.resolveFinalizeTranscript(
            partial: partial,
            completed: "world"
        )
        #expect(resolved == "Hello world")
    }

    @Test func liveSessionSuppressesTranscriptUntilFinalize() async throws {
        let client = MockRealtimeTranscriptionClient(liveResult: .success("final words"))
        var uiEvents: [RealtimeTranscriptEvent] = []
        let session = try await client.beginLiveSession(
            baseURL: "https://space.ai-builders.com/backend",
            token: "token",
            model: "gpt-realtime",
            context: .empty,
            onEvent: { uiEvents.append($0) }
        )

        await session.appendAudioChunk(Data(repeating: 0, count: 100))
        await client.emitLiveEvent(.textDelta(content: "ignored during recording", isNewResponse: true))
        await client.emitLiveEvent(.recoveryStarted)
        #expect(uiEvents.contains { if case .textDelta = $0 { return true }; return false } == false)

        let finalized = try await session.finalize(onPartialTranscript: { _ in })
        await session.cancel()

        #expect(finalized == "final words")
        #expect(uiEvents.contains(.textDelta(content: "final words", isNewResponse: true)))
    }

    @Test func mockLiveSessionStreamsTranscriptAndFinalize() async throws {
        let client = MockRealtimeTranscriptionClient(liveResult: .success("streamed words"))
        var events: [RealtimeTranscriptEvent] = []
        let session = try await client.beginLiveSession(
            baseURL: "https://space.ai-builders.com/backend",
            token: "token",
            model: "gpt-realtime",
            context: .empty,
            onEvent: { events.append($0) }
        )

        await session.appendAudioChunk(Data(repeating: 0, count: 100))
        let finalized = try await session.finalize(onPartialTranscript: { _ in })
        await session.cancel()

        #expect(finalized == "streamed words")
        #expect(events.contains(.status(.connected)))
        #expect(events.contains(.textDelta(content: "streamed words", isNewResponse: true)))
        #expect(events.contains(.status(.idle)))
    }

    @Test func publicClientTranscribesPreservedAudioAfterAbort() async throws {
        let client = VoiceFlowClient.makeStub(liveTranscript: "live words", bulkTranscript: "retried words")
        let session = try await client.startSession()

        await session.sendAudioChunk(Data(repeating: 7, count: RealtimeTranscriptionConfig.minCommitAudioBytes))
        let preserved = try #require(await session.abortPreservingAudio())

        #expect(preserved.byteCount == RealtimeTranscriptionConfig.minCommitAudioBytes)
        let result = try await client.transcribe(preservedAudio: preserved)
        #expect(result.text == "retried words")
        await client.discardPreservedAudio(preserved)
    }
}

/// Opt-in live WebSocket tests against AI Builder Space.
///
/// Disabled by default. Run via `./scripts/test_live_integration.sh` (sets `VOICEFLOW_LIVE_WS=1`
/// and loads `.env`). Default `./scripts/test_unit.sh` skips this suite entirely.
///
/// Observed wire protocol (2026-05-26, ticket-based realtime API):
/// - POST `https://space.ai-builders.com/backend/v1/audio/realtime/sessions` with Bearer token
/// - WebSocket `wss://space.ai-builders.com/backend/v1/audio/realtime/ws?ticket=...` (ticket auth, no Bearer on WS)
/// - Server → client: `session_ready`, `transcript_delta`, `transcript_completed`, `session_stopped`
/// - Client → server: `start`, binary PCM16 mono 24 kHz, `commit`, `stop`
@Suite(.serialized)
@MainActor
struct LiveWebSocketIntegrationTests {
    @Test func liveWebSocketHandshakeAndStartRecording() async throws {
        guard let credentials = try LiveIntegrationTestSupport.resolveCredentials() else {
            return
        }

        let events = EventCollector()
        let client = RealtimeTranscriptionClient()
        let session = try await client.beginLiveSession(
            baseURL: credentials.endpoint,
            token: credentials.token,
            model: RealtimeTranscriptionConfig.defaultModel,
            onEvent: { event in
                Task { await events.append(event) }
            }
        )

        do {
            let phase = try await LiveIntegrationTestSupport.waitUntilConnected(session: session)
            #expect(phase == .connected)

            let statusEvent = try await LiveIntegrationTestSupport.waitForEvent(
                { if case .status(.connected) = $0 { return true }; return false },
                from: events
            )
            #expect(statusEvent == .status(.connected))

            await session.heartbeat()
        } catch {
            await session.cancel()
            throw error
        }

        await session.cancel()
    }

    @Test func liveWebSocketAcceptsPCMChunkAndStopRecording() async throws {
        guard let credentials = try LiveIntegrationTestSupport.resolveCredentials() else {
            return
        }

        let events = EventCollector()
        let client = RealtimeTranscriptionClient()
        let session = try await client.beginLiveSession(
            baseURL: credentials.endpoint,
            token: credentials.token,
            model: RealtimeTranscriptionConfig.defaultModel,
            onEvent: { event in
                Task { await events.append(event) }
            }
        )

        do {
            _ = try await LiveIntegrationTestSupport.waitUntilConnected(session: session)

            let pcmChunk = Data(repeating: 1, count: RealtimeTranscriptionConfig.chunkByteSize)
            for _ in 0..<3 {
                await session.appendAudioChunk(pcmChunk)
            }

            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    _ = try await session.finalize(onPartialTranscript: nil)
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(25))
                    throw LiveIntegrationTestError.connectionFailed("Timed out waiting for commit/stop finalize")
                }
                try await group.next()
                group.cancelAll()
            }

            let snapshot = await events.snapshot()
            let sawGenerating = snapshot.contains { event in
                if case .status(.generating) = event { return true }
                return false
            }
            let sawIdle = snapshot.contains { event in
                if case .status(.idle) = event { return true }
                return false
            }
            #expect(sawGenerating || sawIdle)
        } catch {
            await session.cancel()
            throw error
        }

        await session.cancel()
    }
}
