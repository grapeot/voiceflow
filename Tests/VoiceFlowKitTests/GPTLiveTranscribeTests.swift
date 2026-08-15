import Foundation
import Testing
@testable import VoiceFlowKit

@Suite("GPT Live Transcribe")
struct GPTLiveTranscribeTests {
    @Test func strategyRawValuesCodableAndCapabilitiesRemainStable() throws {
        #expect(VoiceFlowRecordingStrategy.openAIRealtime.rawValue == "openAIRealtime")
        #expect(VoiceFlowRecordingStrategy.gptLiveTranscribe.rawValue == "gptLiveTranscribe")
        #expect(VoiceFlowRecordingStrategy.grokBatch.rawValue == "grokBatch")
        #expect(VoiceFlowRecordingStrategy.localQwen3ASR.rawValue == "localQwen3ASR")
        #expect(VoiceFlowRecordingStrategy.openAIRealtime.usesRealtimeTransport)
        #expect(VoiceFlowRecordingStrategy.gptLiveTranscribe.usesRealtimeTransport)
        #expect(!VoiceFlowRecordingStrategy.grokBatch.usesRealtimeTransport)
        #expect(!VoiceFlowRecordingStrategy.localQwen3ASR.usesRealtimeTransport)
        #expect(VoiceFlowRecordingStrategy.localQwen3ASR.recordsPCM)
        #expect(VoiceFlowRecordingStrategy.grokBatch.recordsPCM == false)
        #expect(VoiceFlowRecordingStrategy.localQwen3ASR.realtimeModel(configuredModel: "x") == nil)

        for strategy in VoiceFlowRecordingStrategy.allCases {
            let data = try JSONEncoder().encode(strategy)
            #expect(try JSONDecoder().decode(VoiceFlowRecordingStrategy.self, from: data) == strategy)
        }
    }

    @Test func liveStrategyUsesExactModelAndPreservesContext() async throws {
        let mock = MockRealtimeTranscriptionClient()
        let client = VoiceFlowClient(
            config: VoiceFlowConfig(
                tokenProvider: { "token" },
                model: "custom-realtime-model",
                prompt: "Keep punctuation",
                terms: ["VoiceFlowKit"]
            ),
            transcriber: mock
        )

        let session = try await client.startSession(strategy: .gptLiveTranscribe)

        #expect(session.strategy == .gptLiveTranscribe)
        #expect(await mock.lastLiveModel == "gpt-live-transcribe")
        #expect(await mock.lastLiveStrategy == .gptLiveTranscribe)
        #expect(await mock.lastLiveContext == RealtimeSessionContext(
            prompt: "Keep punctuation",
            terms: ["VoiceFlowKit"]
        ))
        await session.cancel()
    }

    @Test func realtimeStrategyKeepsConfiguredCustomModel() async throws {
        let mock = MockRealtimeTranscriptionClient()
        let client = VoiceFlowClient(
            config: VoiceFlowConfig(tokenProvider: { "token" }, model: "custom-realtime-model"),
            transcriber: mock
        )

        let session = try await client.startSession(strategy: .openAIRealtime)

        #expect(await mock.lastLiveModel == "custom-realtime-model")
        #expect(await mock.lastLiveStrategy == .openAIRealtime)
        await session.cancel()
    }

    @Test func liveStrategyUsesRealtimePCMRecordingPath() async throws {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceflow-gpt-live-capture-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let recorder = MockAudioRecorder(outputURL: outputURL, outputPCMData: Data(repeating: 1, count: 9_600))

        try await recorder.startRecording(strategy: .gptLiveTranscribe, onPCMChunk: nil)
        let recordedURL = try await recorder.stopRecording()

        #expect(recorder.recordingStrategy == .gptLiveTranscribe)
        #expect(recordedURL.pathExtension == "wav")
        #expect(try PCM16WAVWriter.readPCM(from: recordedURL).count == 9_600)
    }

    @Test func grokCannotStartRealtimeSession() async {
        let client = VoiceFlowClient.makeStub()
        do {
            _ = try await client.startSession(strategy: .grokBatch)
            Issue.record("Expected a typed strategy error")
        } catch let error as VoiceFlowError {
            #expect(error == .unsupportedRecordingStrategy(.grokBatch))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func fileAndPreservedRetriesKeepLiveStrategyAndModel() async throws {
        let wavURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceflow-gpt-live-route-\(UUID().uuidString).wav")
        try PCM16WAVWriter.write(pcmData: Data(repeating: 1, count: 9_600), to: wavURL)
        defer { try? FileManager.default.removeItem(at: wavURL) }

        let mock = MockRealtimeTranscriptionClient(
            liveResult: .success("live result"),
            bulkResult: .success("bulk result")
        )
        let client = VoiceFlowClient(
            config: VoiceFlowConfig(tokenProvider: { "token" }, model: "custom-realtime-model"),
            transcriber: mock
        )

        _ = try await client.transcribe(audioFile: wavURL, strategy: .gptLiveTranscribe)
        #expect(await mock.lastBulkModel == "gpt-live-transcribe")
        #expect(await mock.lastBulkStrategy == .gptLiveTranscribe)

        let session = try await client.startSession(strategy: .gptLiveTranscribe)
        await session.sendAudioChunk(Data(repeating: 2, count: 9_600))
        let preserved = try #require(await session.abortPreservingAudio())
        #expect(preserved.strategy == .gptLiveTranscribe)

        await client.updateConfig(VoiceFlowConfig(
            tokenProvider: { "new-token" },
            model: "different-realtime-model"
        ))
        _ = try await client.transcribe(preservedAudio: preserved)

        #expect(await mock.lastBulkModel == "gpt-live-transcribe")
        #expect(await mock.lastBulkStrategy == .gptLiveTranscribe)
        await client.discardPreservedAudio(preserved)
    }

    @Test func preservedRealtimeRetryKeepsOriginalCustomModel() async throws {
        let mock = MockRealtimeTranscriptionClient(bulkResult: .success("bulk result"))
        let client = VoiceFlowClient(
            config: VoiceFlowConfig(tokenProvider: { "token" }, model: "original-custom-model"),
            transcriber: mock
        )

        let session = try await client.startSession(strategy: .openAIRealtime)
        await session.sendAudioChunk(Data(repeating: 3, count: 9_600))
        let preserved = try #require(await session.abortPreservingAudio())

        await client.updateConfig(VoiceFlowConfig(
            tokenProvider: { "new-token" },
            model: "replacement-model"
        ))
        _ = try await client.transcribe(preservedAudio: preserved)

        #expect(preserved.strategy == .openAIRealtime)
        #expect(await mock.lastBulkModel == "original-custom-model")
        #expect(await mock.lastBulkStrategy == .openAIRealtime)
        await client.discardPreservedAudio(preserved)
    }

    @Test func liveTimeoutTracksAudioDurationWithoutChangingRealtimeTimeout() {
        #expect(RealtimeTranscriptionSupport.timeoutSeconds(
            strategy: .openAIRealtime,
            pcmByteCount: 48_000 * 300
        ) == 30)
        #expect(RealtimeTranscriptionSupport.timeoutSeconds(
            strategy: .gptLiveTranscribe,
            pcmByteCount: 48_000 * 60
        ) == 120)
        #expect(RealtimeTranscriptionSupport.timeoutSeconds(
            strategy: .gptLiveTranscribe,
            pcmByteCount: 48_000 * 300
        ) == 360)
        #expect(RealtimeTranscriptionSupport.timeoutSeconds(
            strategy: .gptLiveTranscribe,
            pcmByteCount: 48_000
        ) == 61)
    }

    @Test func liveWaitsForTranscriptAndTurnCompletionBeforeStop() {
        #expect(RealtimeTranscriptionSupport.isReadyToSendStop(
            strategy: .openAIRealtime,
            receivedTranscriptCompleted: true,
            receivedTurnCompleted: false
        ))
        #expect(!RealtimeTranscriptionSupport.isReadyToSendStop(
            strategy: .gptLiveTranscribe,
            receivedTranscriptCompleted: true,
            receivedTurnCompleted: false
        ))
        #expect(RealtimeTranscriptionSupport.isReadyToSendStop(
            strategy: .gptLiveTranscribe,
            receivedTranscriptCompleted: true,
            receivedTurnCompleted: true
        ))
    }

    @Test func terminalStateRequiresBothLiveEventsAndServerAcknowledgement() {
        var state = RealtimeTerminalState(strategy: .gptLiveTranscribe)

        let readyAfterTranscript = state.observe(eventType: "transcript_completed")
        #expect(!readyAfterTranscript)
        #expect(!state.acceptsSessionStopped())
        let readyAfterTurn = state.observe(eventType: "turn_completed")
        #expect(readyAfterTurn)
        #expect(!state.acceptsSessionStopped())

        state.markStopSent()
        #expect(state.acceptsSessionStopped())
        let readyAfterStop = state.observe(eventType: "turn_completed")
        #expect(!readyAfterStop)
    }

    @Test func completedTranscriptIsAuthoritativeOverLongerPartialText() {
        #expect(RealtimeTranscriptionSupport.resolveFinalizeTranscript(
            partial: "old attempt plus duplicated text",
            completed: "authoritative final"
        ) == "authoritative final")
    }

    @Test func finalizeWaitRegistersBeforeImmediateTerminalSignal() async throws {
        let coordinator = FinalizeWaitCoordinator()
        let attemptID = UUID()
        await coordinator.prepare(attemptID: attemptID)

        try await coordinator.wait(attemptID: attemptID, timeoutSeconds: 1) {
            await coordinator.resolve(.success(()), attemptID: attemptID)
        }
    }

    @Test func finalizeWaitReturnsOnTimeoutWithoutWaitingForStuckCommit() async {
        let coordinator = FinalizeWaitCoordinator()
        let blocker = AsyncTestBlocker()
        let attemptID = UUID()
        await coordinator.prepare(attemptID: attemptID)

        do {
            try await coordinator.wait(attemptID: attemptID, timeoutSeconds: 0.02) {
                await blocker.suspend()
            }
            Issue.record("Expected finalize timeout")
        } catch let error as RealtimeTranscriptionError {
            #expect(error == .connectionLost("Timed out waiting for transcription to finish"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        await blocker.release()
    }

    @Test func finalizeWaitCancellationResumesCaller() async {
        let coordinator = FinalizeWaitCoordinator()
        let blocker = AsyncTestBlocker()
        let attemptID = UUID()
        await coordinator.prepare(attemptID: attemptID)
        let task = Task {
            try await coordinator.wait(attemptID: attemptID, timeoutSeconds: 10) {
                await blocker.suspend()
            }
        }

        await blocker.waitUntilSuspended()
        task.cancel()
        let result = await task.result
        if case .failure(let error) = result {
            #expect(error is CancellationError)
        } else {
            Issue.record("Expected cancellation")
        }
        await blocker.release()
    }

    @Test func gptLiveFinalizeFailureDoesNotCreateSecondTicket() async throws {
        let cache = try AudioChunkCache()
        let factory = TestSessionTransportFactory([])
        let initial = TestSessionTransport {
            throw RealtimeTranscriptionError.connectionLost("finalize failed")
        }
        let handle = RealtimeLiveSessionHandle(
            cache: cache,
            strategy: .gptLiveTranscribe,
            model: "gpt-live-transcribe",
            onEvent: { _ in },
            makeSession: { try await factory.make() }
        )
        try await handle.attachInitialSession(initial)
        await handle.appendAudioChunk(Data(repeating: 1, count: 9_600))

        do {
            _ = try await handle.finalize(onPartialTranscript: nil)
            Issue.record("Expected finalize failure")
        } catch let error as RealtimeTranscriptionError {
            #expect(error == .connectionLost("finalize failed"))
        }

        #expect(await factory.makeCount == 0)
        await handle.cancel()
    }

    @Test func gptLiveAudioTransportFailureDoesNotRecoverAutomatically() async throws {
        let cache = try AudioChunkCache()
        let factory = TestSessionTransportFactory([])
        let initial = TestSessionTransport(
            onAudio: { _ in
                throw RealtimeTranscriptionError.connectionLost("audio send failed")
            },
            onCommit: {}
        )
        let handle = RealtimeLiveSessionHandle(
            cache: cache,
            strategy: .gptLiveTranscribe,
            model: "gpt-live-transcribe",
            onEvent: { _ in },
            makeSession: { try await factory.make() }
        )
        try await handle.attachInitialSession(initial)

        await handle.appendAudioChunk(Data(repeating: 1, count: 9_600))

        #expect(await handle.connectionPhase == .disconnected)
        #expect(await factory.makeCount == 0)
        await handle.cancel()
    }

    @Test func recordingDeltasRemainAccumulatedAcrossGPTLiveFinalize() async throws {
        let cache = try AudioChunkCache()
        let handleBox = TestHandleBox()
        let publicEvents = LockedTranscriptCollector()
        let finalizeSnapshots = LockedTranscriptCollector()
        let initial = TestSessionTransport {
            guard let handle = handleBox.handle else { return }
            await handle.ingestServerEvent(.textDelta(content: " Final", isNewResponse: false))
            await handle.ingestServerEvent(.textDelta(content: "Authoritative full transcript.", isNewResponse: true))
            await handle.ingestServerEvent(.status(.idle))
        }
        let handle = RealtimeLiveSessionHandle(
            cache: cache,
            strategy: .gptLiveTranscribe,
            model: "gpt-live-transcribe",
            onEvent: { event in
                if case .textDelta(let content, _) = event {
                    publicEvents.append(content)
                }
            },
            makeSession: { throw RealtimeTranscriptionError.sessionUnavailable }
        )
        handleBox.handle = handle
        try await handle.attachInitialSession(initial)
        await handle.appendAudioChunk(Data(repeating: 1, count: 9_600))

        await handle.ingestServerEvent(.textDelta(content: "The first ", isNewResponse: false))
        await handle.ingestServerEvent(.textDelta(content: "sentence.", isNewResponse: false))
        let transcript = try await handle.finalize { snapshot in
            finalizeSnapshots.append(snapshot)
        }

        #expect(publicEvents.snapshot == ["The first ", "The first sentence."])
        #expect(finalizeSnapshots.snapshot == [
            "The first sentence. Final",
            "Authoritative full transcript."
        ])
        #expect(transcript == "Authoritative full transcript.")
    }

    @Test func pendingInitialConnectionFinalizeWaitsWithoutCreatingSecondTicket() async throws {
        let cache = try AudioChunkCache()
        let blocker = AsyncTestBlocker()
        let factoryCalls = TestCallCounter()
        let handleBox = TestHandleBox()
        let initial = TestSessionTransport {
            guard let handle = handleBox.handle else { return }
            await handle.ingestServerEvent(.textDelta(content: "slow handshake transcript", isNewResponse: true))
            await handle.ingestServerEvent(.status(.idle))
        }
        let handle = RealtimeLiveSessionHandle(
            cache: cache,
            strategy: .gptLiveTranscribe,
            model: "gpt-live-transcribe",
            onEvent: { _ in },
            makeSession: {
                let callCount = await factoryCalls.increment()
                guard callCount == 1 else {
                    throw RealtimeTranscriptionError.connectionLost("unexpected second ticket")
                }
                await blocker.suspend()
                return initial
            }
        )
        handleBox.handle = handle

        await handle.startInitialConnection()
        await blocker.waitUntilSuspended()
        await handle.appendAudioChunk(Data(repeating: 3, count: 9_600))
        let finalizeTask = Task {
            try await handle.finalize(onPartialTranscript: nil)
        }
        while await handle.connectionPhase != .generating {
            await Task.yield()
        }

        #expect(await factoryCalls.count == 1)
        await blocker.release()

        #expect(try await finalizeTask.value == "slow handshake transcript")
        #expect(await factoryCalls.count == 1)
    }

    @Test func realtimeReplayUsesOnlySecondAttemptAuthoritativeTranscript() async throws {
        let cache = try AudioChunkCache()
        let handleBox = TestHandleBox()
        let initial = TestSessionTransport {
            guard let handle = handleBox.handle else { return }
            await handle.ingestServerEvent(.textDelta(content: "old partial ", isNewResponse: false))
            throw RealtimeTranscriptionError.connectionLost("retry")
        }
        let replacement = TestSessionTransport {
            guard let handle = handleBox.handle else { return }
            await handle.ingestServerEvent(.textDelta(content: "authoritative final", isNewResponse: true))
            await handle.ingestServerEvent(.status(.idle))
        }
        let factory = TestSessionTransportFactory([replacement])
        let handle = RealtimeLiveSessionHandle(
            cache: cache,
            strategy: .openAIRealtime,
            model: "gpt-realtime",
            onEvent: { _ in },
            makeSession: { try await factory.make() }
        )
        handleBox.handle = handle
        try await handle.attachInitialSession(initial)
        await handle.appendAudioChunk(Data(repeating: 2, count: 9_600))

        let transcript = try await handle.finalize(onPartialTranscript: nil)

        #expect(transcript == "authoritative final")
        #expect(await factory.makeCount == 1)
    }

    @Test func sessionPayloadDoesNotInventUpstreamProtocolFields() {
        let payload = RealtimeTranscriptionClient.sessionCreatePayload(
            model: "gpt-live-transcribe",
            vad: false,
            context: RealtimeSessionContext(prompt: "Prompt", terms: ["Term"])
        )

        #expect(payload["model"] as? String == "gpt-live-transcribe")
        #expect(payload["vad"] as? Bool == false)
        #expect(payload["prompt"] as? String == "Prompt")
        #expect(payload["terms"] as? [String] == ["Term"])
        #expect(payload["engine"] == nil)
        #expect(payload["intent"] == nil)
    }

    @Test func partialTranscriptWithoutTerminalEventIsNotFinal() async {
        let progress = BulkTranscriptionProgress()
        await progress.handle(.textDelta(content: "partial only", isNewResponse: true), onPartialTranscript: nil)

        do {
            _ = try await progress.resolvedTranscript()
            Issue.record("Expected partial-only progress to time out")
        } catch let error as RealtimeTranscriptionError {
            #expect(error == .connectionLost("Timed out waiting for transcription to finish"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

private actor AsyncTestBlocker {
    private var continuation: CheckedContinuation<Void, Never>?
    private var suspended = false

    func suspend() async {
        await withCheckedContinuation { continuation in
            suspended = true
            self.continuation = continuation
        }
    }

    func waitUntilSuspended() async {
        while !suspended {
            await Task.yield()
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private final class TestHandleBox: @unchecked Sendable {
    var handle: RealtimeLiveSessionHandle?
}

private final class LockedTranscriptCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func append(_ value: String) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    var snapshot: [String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

private actor TestSessionTransport: RealtimeSessionTransport {
    private let onAudio: @Sendable (Data) async throws -> Void
    private let onCommit: @Sendable () async throws -> Void
    private var audioByteCount = 0

    init(
        onAudio: @escaping @Sendable (Data) async throws -> Void = { _ in },
        onCommit: @escaping @Sendable () async throws -> Void
    ) {
        self.onAudio = onAudio
        self.onCommit = onCommit
    }

    var pendingCommitAudioBytes: Int {
        audioByteCount
    }

    func sendAudioChunk(_ chunk: Data) async throws {
        try await onAudio(chunk)
        audioByteCount += chunk.count
    }

    func sendCommit() async throws {
        try await onCommit()
    }

    func ping() {}
    func close() {}
}

private actor TestSessionTransportFactory {
    private var transports: [any RealtimeSessionTransport]
    private(set) var makeCount = 0

    init(_ transports: [any RealtimeSessionTransport]) {
        self.transports = transports
    }

    func make() throws -> any RealtimeSessionTransport {
        makeCount += 1
        guard !transports.isEmpty else {
            throw RealtimeTranscriptionError.sessionUnavailable
        }
        return transports.removeFirst()
    }
}

private actor TestCallCounter {
    private(set) var count = 0

    func increment() -> Int {
        count += 1
        return count
    }
}
