import Foundation
import OSLog

private let sessionLogger = Logger(subsystem: "com.voiceflow.kit", category: "Session")

private nonisolated struct FinalizeTranscriptAccumulator: Sendable {
    private(set) var partialText = ""
    private(set) var completedText: String?

    var resolvedText: String {
        RealtimeTranscriptionSupport.resolveFinalizeTranscript(partial: partialText, completed: completedText)
    }

    mutating func reset() {
        partialText = ""
        completedText = nil
    }

    mutating func appendDelta(_ content: String) {
        partialText += content
    }

    mutating func setCompleted(_ content: String) {
        completedText = content
    }
}

private nonisolated final class LiveSessionHandleBox: @unchecked Sendable {
    var handle: RealtimeLiveSessionHandle?
}

/// Optional per-call hints the host wants the transcription model to
/// read before working. The backend concatenates these into the
/// underlying prompt — there's no separate "language" knob because the
/// model treats language hints as natural-language context.
struct RealtimeSessionContext: Sendable, Equatable {
    public var prompt: String?
    public var terms: [String]

    public init(prompt: String? = nil, terms: [String] = []) {
        self.prompt = prompt
        self.terms = terms
    }

    public static let empty = RealtimeSessionContext()
}

protocol RealtimeTranscribing: Sendable {
    func beginLiveSession(
        baseURL: String,
        token: String,
        model: String,
        strategy: VoiceFlowRecordingStrategy,
        context: RealtimeSessionContext,
        onEvent: @escaping @Sendable (RealtimeTranscriptEvent) -> Void
    ) async throws -> RealtimeLiveTranscriptionSession

    func transcribeBulkPCM(
        pcmData: Data,
        baseURL: String,
        token: String,
        model: String,
        strategy: VoiceFlowRecordingStrategy,
        context: RealtimeSessionContext,
        onPartialTranscript: (@Sendable (String) -> Void)?
    ) async throws -> String
}

protocol RealtimeLiveTranscriptionSession: Sendable {
    func appendAudioChunk(_ chunk: Data) async
    func heartbeat() async
    func finalize(onPartialTranscript: (@Sendable (String) -> Void)?) async throws -> String
    func cancel() async
    func abortPreservingAudio() async throws -> VoiceFlowPreservedAudio?
    var connectionPhase: RealtimeConnectionPhase { get async }
}

protocol RealtimeSessionTransport: Sendable {
    func sendAudioChunk(_ chunk: Data) async throws
    func sendCommit() async throws
    func ping() async throws
    func close() async
    var pendingCommitAudioBytes: Int { get async }
}

actor FinalizeWaitCoordinator {
    private var attemptID: UUID?
    private var waiter: CheckedContinuation<Void, Error>?
    private var pendingResult: Result<Void, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?

    func prepare(attemptID: UUID) {
        timeoutTask?.cancel()
        operationTask?.cancel()
        if let waiter {
            waiter.resume(throwing: CancellationError())
        }
        self.attemptID = attemptID
        waiter = nil
        pendingResult = nil
        timeoutTask = nil
        operationTask = nil
    }

    func wait(
        attemptID: UUID,
        timeoutSeconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> Void
    ) async throws {
        defer { finish(attemptID: attemptID) }
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard self.attemptID == attemptID else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if let pendingResult {
                    self.pendingResult = nil
                    continuation.resume(with: pendingResult)
                    return
                }

                waiter = continuation
                timeoutTask = Task { [weak self] in
                    do {
                        try await Task.sleep(for: .seconds(timeoutSeconds))
                    } catch {
                        return
                    }
                    await self?.resolve(
                        .failure(RealtimeTranscriptionError.connectionLost(
                            "Timed out waiting for transcription to finish"
                        )),
                        attemptID: attemptID
                    )
                }
                operationTask = Task { [weak self] in
                    do {
                        try await operation()
                    } catch {
                        await self?.resolve(.failure(error), attemptID: attemptID)
                    }
                }
            }
        } onCancel: {
            Task { [weak self] in
                await self?.resolve(.failure(CancellationError()), attemptID: attemptID)
            }
        }
    }

    func resolve(_ result: Result<Void, Error>, attemptID: UUID) {
        guard self.attemptID == attemptID else { return }
        timeoutTask?.cancel()
        if let waiter {
            self.waiter = nil
            waiter.resume(with: result)
        } else if case nil = pendingResult {
            pendingResult = result
        }
    }

    private func finish(attemptID: UUID) {
        guard self.attemptID == attemptID else { return }
        timeoutTask?.cancel()
        operationTask?.cancel()
        self.attemptID = nil
        waiter = nil
        pendingResult = nil
        timeoutTask = nil
        operationTask = nil
    }
}

actor RealtimeTranscriptionSession: RealtimeSessionTransport {
    private let webSocketTask: URLSessionWebSocketTask
    private let urlSession: URLSession
    private let sender: RealtimeWebSocketSender
    private let onEvent: @Sendable (RealtimeTranscriptEvent) async -> Void
    private var receiveTask: Task<Void, Never>?
    private var isClosed = false
    private var hasSentCommit = false
    private var shouldSendStopAfterCompletion = false
    private var terminalState: RealtimeTerminalState
    private var enqueuedAudioBytes = 0

    init(
        webSocketTask: URLSessionWebSocketTask,
        urlSession: URLSession,
        strategy: VoiceFlowRecordingStrategy,
        onEvent: @escaping @Sendable (RealtimeTranscriptEvent) async -> Void
    ) {
        self.webSocketTask = webSocketTask
        self.urlSession = urlSession
        self.sender = RealtimeWebSocketSender(task: webSocketTask)
        self.terminalState = RealtimeTerminalState(strategy: strategy)
        self.onEvent = onEvent
    }

    func startReceiving() {
        guard receiveTask == nil else { return }
        receiveTask = Task { await receiveLoop() }
    }

    func sendStartControl(model: String, vad: Bool = true) async throws {
        let message = try RealtimeMessageParser.startControlMessage(model: model, vad: vad)
        try await sender.send(.string(message))
    }

    func sendAudioChunk(_ chunk: Data) async throws {
        guard !chunk.isEmpty, !isClosed, !hasSentCommit else { return }
        enqueuedAudioBytes += chunk.count
        try await sender.send(.data(chunk))
    }

    var pendingCommitAudioBytes: Int {
        enqueuedAudioBytes
    }

    func sendCommit() async throws {
        guard !hasSentCommit else { return }
        guard enqueuedAudioBytes >= RealtimeTranscriptionConfig.minCommitAudioBytes else {
            throw RealtimeTranscriptionError.websocketError(
                "Insufficient audio buffer for commit (\(enqueuedAudioBytes) bytes)"
            )
        }
        hasSentCommit = true
        try await sender.flush()
        shouldSendStopAfterCompletion = true
        try await sender.send(.string(RealtimeTranscriptionConfig.commitMessage))
    }

    func sendStop() async throws {
        guard !isClosed else { return }
        try await sender.send(.string(RealtimeTranscriptionConfig.stopMessage))
        terminalState.markStopSent()
    }

    func sendCommitAndStop() async throws {
        try await sendCommit()
    }

    func ping() async throws {
        guard !isClosed else {
            throw RealtimeTranscriptionError.connectionLost("WebSocket connection is closed")
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            webSocketTask.sendPing { error in
                if let error {
                    continuation.resume(throwing: RealtimeTranscriptionError.connectionLost(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func close() async {
        guard !isClosed else { return }
        isClosed = true
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask.cancel(with: .goingAway, reason: nil)
        urlSession.invalidateAndCancel()
        await onEvent(.disconnected)
    }

    private func receiveLoop() async {
        while !Task.isCancelled, !isClosed {
            do {
                let message = try await webSocketTask.receive()
                let socketEvent = try RealtimeMessageParser.parseSocketMessage(message)
                let isReadyToSendStop = terminalState.observe(eventType: socketEvent.type)
                if socketEvent.type == "session_stopped", !terminalState.acceptsSessionStopped() {
                    await onEvent(.error(message: "Received session_stopped before client stop"))
                } else if let event = RealtimeMessageParser.parseSocketEvent(socketEvent) {
                    await onEvent(event)
                }
                if shouldSendStopAfterCompletion, isReadyToSendStop {
                    shouldSendStopAfterCompletion = false
                    do {
                        try await sender.send(.string(RealtimeTranscriptionConfig.stopMessage))
                        terminalState.markStopSent()
                    } catch {
                        await onEvent(.error(message: String(describing: error)))
                    }
                }
            } catch {
                if !Task.isCancelled, !isClosed {
                    await onEvent(.disconnected)
                }
                break
            }
        }
    }
}

actor RealtimeLiveSessionHandle: RealtimeLiveTranscriptionSession {
    private enum InitialConnectionState {
        case notStarted
        case connecting(id: UUID, task: Task<Void, Never>)
        case completed(Result<Void, Error>)
    }

    private let cache: AudioChunkCache
    private let strategy: VoiceFlowRecordingStrategy
    private let model: String
    private let makeSession: @Sendable () async throws -> any RealtimeSessionTransport
    private let onEvent: @Sendable (RealtimeTranscriptEvent) -> Void
    private let finalizeWaitCoordinator = FinalizeWaitCoordinator()
    private var session: (any RealtimeSessionTransport)?
    private var initialConnectionState: InitialConnectionState = .notStarted
    private var isRecovering = false
    private var phase: RealtimeConnectionPhase = .connecting
    private var isFinalizing = false
    private var finalizeAttemptID: UUID?
    private var finalizeText = FinalizeTranscriptAccumulator()
    private var finalizePartialCallback: (@Sendable (String) -> Void)?
    private var hasPreservedAudio = false
    private var isTerminated = false
    private var isClosingFailedSession = false

    init(
        cache: AudioChunkCache,
        strategy: VoiceFlowRecordingStrategy,
        model: String,
        onEvent: @escaping @Sendable (RealtimeTranscriptEvent) -> Void,
        makeSession: @escaping @Sendable () async throws -> any RealtimeSessionTransport
    ) {
        self.cache = cache
        self.strategy = strategy
        self.model = model
        self.onEvent = onEvent
        self.makeSession = makeSession
    }

    var connectionPhase: RealtimeConnectionPhase {
        phase
    }

    func startInitialConnection() {
        guard case .notStarted = initialConnectionState else { return }
        let connectionID = UUID()
        let makeSession = self.makeSession
        let task = Task { [weak self] in
            do {
                let initialSession = try await makeSession()
                guard let self else {
                    await initialSession.close()
                    return
                }
                await self.completeInitialConnection(initialSession, connectionID: connectionID)
            } catch {
                await self?.failInitialConnection(error, connectionID: connectionID)
            }
        }
        initialConnectionState = .connecting(id: connectionID, task: task)
    }

    func attachInitialSession(_ newSession: any RealtimeSessionTransport) async throws {
        guard !isTerminated else {
            await newSession.close()
            return
        }
        guard session == nil, !isRecovering,
              case .notStarted = initialConnectionState else {
            await newSession.close()
            return
        }
        do {
            try await replayCache(to: newSession)
            session = newSession
            initialConnectionState = .completed(.success(()))
            phase = .connected
        } catch {
            await newSession.close()
            initialConnectionState = .completed(.failure(error))
            phase = .disconnected
            throw error
        }
    }

    func appendAudioChunk(_ chunk: Data) async {
        guard !hasPreservedAudio, !isTerminated else { return }
        do {
            try cache.append(chunk)
            guard !isRecovering, let session else { return }
            try await session.sendAudioChunk(chunk)
        } catch {
            if strategy == .gptLiveTranscribe {
                await failTransportWithoutRecovery(reason: error)
            } else {
                await recover(reason: error)
            }
        }
    }

    func heartbeat() async {
        guard !isTerminated else { return }
        guard !isRecovering, let session else { return }
        do {
            try await session.ping()
        } catch {
            if strategy == .gptLiveTranscribe {
                await failTransportWithoutRecovery(reason: error)
            } else {
                await recover(reason: error)
            }
        }
    }

    func finalize(onPartialTranscript: (@Sendable (String) -> Void)? = nil) async throws -> String {
        isFinalizing = true
        if strategy != .gptLiveTranscribe {
            finalizeText.reset()
        }
        finalizePartialCallback = onPartialTranscript
        phase = .generating
        defer {
            isFinalizing = false
            finalizeAttemptID = nil
            finalizePartialCallback = nil
        }

        let maxAttempts = strategy == .gptLiveTranscribe ? 1 : 2
        var lastError: Error = RealtimeTranscriptionError.emptyTranscript

        for attempt in 0..<maxAttempts {
            let attemptID = UUID()
            finalizeAttemptID = attemptID
            if strategy != .gptLiveTranscribe {
                finalizeText.reset()
            }
            await finalizeWaitCoordinator.prepare(attemptID: attemptID)
            try await ensureSessionReadyForFinalize()
            guard var activeSession = session else {
                throw RealtimeTranscriptionError.sessionUnavailable
            }

            if cache.byteCount >= RealtimeTranscriptionConfig.minCommitAudioBytes,
               await activeSession.pendingCommitAudioBytes < RealtimeTranscriptionConfig.minCommitAudioBytes {
                let syncError = RealtimeTranscriptionError.connectionLost("Audio not fully synced before finalize")
                guard strategy != .gptLiveTranscribe else { throw syncError }
                await recover(reason: syncError)
                try await ensureSessionReadyForFinalize()
                guard let recoveredSession = session else {
                    throw RealtimeTranscriptionError.sessionUnavailable
                }
                activeSession = recoveredSession
            }

            let commitSession = activeSession
            do {
                try await waitForFinalizeResult(attemptID: attemptID) {
                    try await commitSession.sendCommit()
                }
                let resolved = finalizeText.resolvedText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !resolved.isEmpty {
                    let finalText = finalizeText.resolvedText
                    await terminate(removeCache: true)
                    return finalText
                }
                lastError = RealtimeTranscriptionError.emptyTranscript
            } catch {
                lastError = error
            }

            if attempt < maxAttempts - 1 {
                await recover(reason: lastError)
            }
        }

        throw lastError
    }

    private func ensureSessionReadyForFinalize() async throws {
        do {
            try await awaitInitialConnection()
        } catch {
            guard strategy != .gptLiveTranscribe else { throw error }
            await recover(reason: error)
        }
        while isRecovering {
            try await Task.sleep(for: .milliseconds(100))
        }
        if session == nil {
            let unavailableError = RealtimeTranscriptionError.connectionLost("Session unavailable before finalize")
            guard strategy != .gptLiveTranscribe else { throw unavailableError }
            await recover(reason: unavailableError)
        }
        while isRecovering {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard session != nil else {
            throw RealtimeTranscriptionError.sessionUnavailable
        }
    }

    private func awaitInitialConnection() async throws {
        while true {
            switch initialConnectionState {
            case .notStarted:
                startInitialConnection()
            case .connecting(_, let task):
                await task.value
                try Task.checkCancellation()
            case .completed(.success):
                return
            case .completed(.failure(let error)):
                throw error
            }
        }
    }

    private func completeInitialConnection(
        _ newSession: any RealtimeSessionTransport,
        connectionID: UUID
    ) async {
        guard !isTerminated,
              case .connecting(let activeID, _) = initialConnectionState,
              activeID == connectionID else {
            await newSession.close()
            return
        }

        do {
            try await replayCache(to: newSession)
            guard !isTerminated,
                  case .connecting(let activeID, _) = initialConnectionState,
                  activeID == connectionID else {
                await newSession.close()
                return
            }
            session = newSession
            initialConnectionState = .completed(.success(()))
            phase = .connected
        } catch {
            await newSession.close()
            failInitialConnection(error, connectionID: connectionID)
        }
    }

    private func failInitialConnection(_ error: Error, connectionID: UUID) {
        guard case .connecting(let activeID, _) = initialConnectionState,
              activeID == connectionID else { return }
        initialConnectionState = .completed(.failure(error))
        phase = .disconnected
        if !isTerminated {
            onEvent(.recoveryFailed(message: String(describing: error)))
        }
    }

    private func cancelInitialConnection() {
        if case .connecting(_, let task) = initialConnectionState {
            task.cancel()
        }
        initialConnectionState = .completed(.failure(CancellationError()))
    }

    private func waitForFinalizeResult(
        attemptID: UUID,
        sendCommit: @escaping @Sendable () async throws -> Void
    ) async throws {
        let timeoutSeconds = RealtimeTranscriptionSupport.timeoutSeconds(
            strategy: strategy,
            pcmByteCount: cache.byteCount
        )
        try await finalizeWaitCoordinator.wait(
            attemptID: attemptID,
            timeoutSeconds: timeoutSeconds,
            operation: sendCommit
        )
    }

    func ingestServerEvent(_ event: RealtimeTranscriptEvent) async {
        await handleServerEvent(event)
    }

    func shouldNotifyUI(for event: RealtimeTranscriptEvent) -> Bool {
        switch event {
        case .textDelta:
            // During finalize the transcript is already delivered to the host
            // via `finalizePartialCallback` with the full *resolved* text.
            // Also forwarding raw per-event textDeltas through the event stream
            // here created a SECOND, competing writer that carries only the
            // single event's content — the two writers produce values that are
            // not prefixes of each other, which breaks the host's append-only
            // invariant and forces a full UITextView reset (the flicker / the
            // "clears to one or two chars then jumps back to full" behavior).
            // The finalize callback is the single authoritative source, so
            // never forward textDeltas through the event stream.
            return false
        case .error(let message):
            return isFinalizing || !RealtimeTranscriptionSupport.isRecoverableBufferTooSmallError(message)
        default:
            return true
        }
    }

    private func completeFinalize(with result: Result<Void, Error>) async {
        guard let finalizeAttemptID else { return }
        await finalizeWaitCoordinator.resolve(result, attemptID: finalizeAttemptID)
    }

    func cancel() async {
        isTerminated = true
        cancelInitialConnection()
        if let session {
            await session.close()
        }
        session = nil
        if !hasPreservedAudio {
            cache.remove()
        }
        phase = .disconnected
    }

    func abortPreservingAudio() async throws -> VoiceFlowPreservedAudio? {
        isTerminated = true
        cancelInitialConnection()
        if let session {
            await session.close()
        }
        session = nil
        isRecovering = false
        phase = .disconnected
        if isFinalizing {
            await completeFinalize(with: .failure(RealtimeTranscriptionError.connectionLost("Session aborted")))
        }
        guard let preserved = cache.preservedAudio(strategy: strategy, model: model) else {
            cache.remove()
            return nil
        }
        hasPreservedAudio = true
        return preserved
    }

    private func terminate(removeCache: Bool) async {
        isTerminated = true
        cancelInitialConnection()
        if let session {
            await session.close()
        }
        session = nil
        isRecovering = false
        phase = .disconnected
        if removeCache {
            cache.remove()
        }
    }

    func handleServerEvent(_ event: RealtimeTranscriptEvent) async {
        switch event {
        case .status(let status):
            switch status {
            case .connected, .connecting:
                if !isFinalizing {
                    phase = .connected
                }
            case .generating:
                phase = .generating
            case .idle:
                phase = .disconnected
                if isFinalizing {
                    let trimmed = finalizeText.resolvedText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty {
                        await completeFinalize(with: .failure(RealtimeTranscriptionError.emptyTranscript))
                    } else {
                        await completeFinalize(with: .success(()))
                    }
                }
            }
        case .disconnected:
            if isClosingFailedSession {
                return
            }
            phase = .disconnected
            if isFinalizing {
                await completeFinalize(with: .failure(RealtimeTranscriptionError.connectionLost("WebSocket disconnected")))
            } else if strategy == .gptLiveTranscribe {
                await failTransportWithoutRecovery(
                    reason: RealtimeTranscriptionError.connectionLost("WebSocket disconnected")
                )
            } else {
                Task { await self.recover(reason: RealtimeTranscriptionError.connectionLost("WebSocket disconnected")) }
            }
        case .error(let message):
            if RealtimeTranscriptionSupport.isRecoverableBufferTooSmallError(message), !isFinalizing {
                break
            }
            if isFinalizing {
                await completeFinalize(with: .failure(RealtimeTranscriptionError.websocketError(message)))
            }
        case .textDelta(let content, let isNewResponse):
            guard !content.isEmpty else { return }
            guard isFinalizing || strategy == .gptLiveTranscribe else { return }
            if isNewResponse {
                finalizeText.setCompleted(content)
            } else {
                finalizeText.appendDelta(content)
            }
            let snapshot = finalizeText.resolvedText
            if isFinalizing {
                finalizePartialCallback?(snapshot)
            } else {
                // GPT Live emits deltas while recording. Surface one accumulated
                // snapshot so hosts never have to merge raw wire fragments.
                onEvent(.textDelta(content: snapshot, isNewResponse: true))
            }
        case .recoveryStarted, .recoveryFailed:
            break
        }
    }

    private func recover(reason: Error) async {
        guard !isTerminated else { return }
        guard !hasPreservedAudio else { return }
        guard strategy != .gptLiveTranscribe else {
            await failTransportWithoutRecovery(reason: reason)
            return
        }
        if case .connecting(_, let task) = initialConnectionState {
            await task.value
        }
        guard !isRecovering else { return }
        isRecovering = true
        phase = .recovering
        onEvent(.recoveryStarted)
        if let session {
            await session.close()
        }
        session = nil

        var lastError = reason
        for attempt in 0..<RealtimeTranscriptionConfig.maxRecoverAttempts {
            if attempt > 0 {
                let delayMs = RealtimeTranscriptionConfig.recoverBackoffBaseMilliseconds * (1 << (attempt - 1))
                try? await Task.sleep(for: .milliseconds(delayMs))
            }
            do {
                let replacement = try await makeSession()
                try await replayCache(to: replacement)
                session = replacement
                phase = .connected
                isRecovering = false
                return
            } catch {
                lastError = error
            }
        }

        phase = .disconnected
        isRecovering = false
        onEvent(.recoveryFailed(message: String(describing: lastError)))
    }

    private func failTransportWithoutRecovery(reason: Error) async {
        guard !isTerminated else { return }
        let failedSession = session
        session = nil
        phase = .disconnected
        onEvent(.recoveryFailed(message: String(describing: reason)))
        guard let failedSession else { return }
        isClosingFailedSession = true
        await failedSession.close()
        isClosingFailedSession = false
    }

    private func replayCache(to targetSession: any RealtimeSessionTransport) async throws {
        var offset = 0
        while true {
            let chunk = try cache.readChunk(offset: offset, maxBytes: RealtimeTranscriptionConfig.replayChunkSize)
            if chunk.isEmpty {
                if offset >= cache.byteCount { return }
                try await Task.sleep(for: .milliseconds(20))
                continue
            }
            try await targetSession.sendAudioChunk(chunk)
            offset += chunk.count
        }
    }
}

struct RealtimeTranscriptionClient: RealtimeTranscribing {
    public init() {}

    public func beginLiveSession(
        baseURL: String,
        token: String,
        model: String = RealtimeTranscriptionConfig.defaultModel,
        strategy: VoiceFlowRecordingStrategy = .openAIRealtime,
        context: RealtimeSessionContext = .empty,
        onEvent: @escaping @Sendable (RealtimeTranscriptEvent) -> Void
    ) async throws -> RealtimeLiveTranscriptionSession {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            throw RealtimeTranscriptionError.missingToken
        }

        let cache = try AudioChunkCache()
        let handleBox = LiveSessionHandleBox()
        let handle = RealtimeLiveSessionHandle(
            cache: cache,
            strategy: strategy,
            model: model,
            onEvent: onEvent
        ) {
            try await Self.makeSession(
                baseURL: baseURL,
                token: trimmedToken,
                model: model,
                strategy: strategy,
                vad: false,
                context: context,
                onEvent: { event in
                    guard let boundHandle = handleBox.handle else { return }
                    await Self.deliverLiveSessionEvent(event, handle: boundHandle, onEvent: onEvent)
                }
            )
        }
        handleBox.handle = handle

        await handle.startInitialConnection()

        return handle
    }

    public func transcribeBulkPCM(
        pcmData: Data,
        baseURL: String,
        token: String,
        model: String = RealtimeTranscriptionConfig.defaultModel,
        strategy: VoiceFlowRecordingStrategy = .openAIRealtime,
        context: RealtimeSessionContext = .empty,
        onPartialTranscript: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        guard !pcmData.isEmpty else {
            throw RealtimeTranscriptionError.emptyTranscript
        }

        let progress = BulkTranscriptionProgress()

        let session = try await Self.makeSession(
            baseURL: baseURL,
            token: token,
            model: model,
            strategy: strategy,
            vad: false,
            context: context,
            onEvent: { event in
                await progress.handle(event, onPartialTranscript: onPartialTranscript)
            }
        )

        defer { Task { await session.close() } }

        for start in stride(from: 0, to: pcmData.count, by: RealtimeTranscriptionConfig.replayChunkSize) {
            let end = min(start + RealtimeTranscriptionConfig.replayChunkSize, pcmData.count)
            try await session.sendAudioChunk(pcmData.subdata(in: start..<end))
        }

        try await session.sendCommitAndStop()

        let deadline = Date().addingTimeInterval(
            RealtimeTranscriptionSupport.timeoutSeconds(
                strategy: strategy,
                pcmByteCount: pcmData.count
            )
        )
        while !(await progress.isFinished), Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }

        return try await progress.resolvedTranscript()
    }

    private static func deliverLiveSessionEvent(
        _ event: RealtimeTranscriptEvent,
        handle: RealtimeLiveSessionHandle,
        onEvent: @escaping @Sendable (RealtimeTranscriptEvent) -> Void
    ) async {
        await handle.ingestServerEvent(event)
        if await handle.shouldNotifyUI(for: event) {
            onEvent(event)
        }
    }

    private static func makeSession(
        baseURL: String,
        token: String,
        model: String,
        strategy: VoiceFlowRecordingStrategy,
        vad: Bool = false,
        context: RealtimeSessionContext = .empty,
        onEvent: @escaping @Sendable (RealtimeTranscriptEvent) async -> Void
    ) async throws -> RealtimeTranscriptionSession {
        let normalizedBase = try RealtimeAPIURLBuilder.normalizedBaseURL(from: baseURL)
        let sessionResponse = try await createRealtimeSession(
            baseURL: normalizedBase,
            token: token,
            model: model,
            vad: vad,
            context: context
        )
        let websocketURL = try RealtimeAPIURLBuilder.realtimeWebSocketURL(
            baseURL: normalizedBase,
            relativePath: sessionResponse.wsURL
        )

        let urlSession = URLSession(configuration: .default)
        let webSocketTask = urlSession.webSocketTask(with: websocketURL)
        webSocketTask.resume()

        let readyEvent = try await receiveSocketEvent(task: webSocketTask)
        guard readyEvent.type == "session_ready" else {
            webSocketTask.cancel(with: .goingAway, reason: nil)
            urlSession.invalidateAndCancel()
            throw RealtimeTranscriptionError.websocketError("Expected session_ready, got \(readyEvent.type)")
        }
        await onEvent(.status(.connected))

        let session = RealtimeTranscriptionSession(
            webSocketTask: webSocketTask,
            urlSession: urlSession,
            strategy: strategy,
            onEvent: onEvent
        )
        await session.startReceiving()
        try await session.sendStartControl(model: model, vad: vad)
        return session
    }

    private static func createRealtimeSession(
        baseURL: URL,
        token: String,
        model: String,
        vad: Bool,
        context: RealtimeSessionContext
    ) async throws -> RealtimeSessionCreateResponse {
        guard let url = RealtimeAPIURLBuilder.buildAPIURL(
            base: baseURL,
            path: RealtimeTranscriptionConfig.sessionCreatePath
        ) else {
            throw RealtimeTranscriptionError.invalidBaseURL
        }

        let payload = sessionCreatePayload(model: model, vad: vad, context: context)

        // Summary log: which optional context fields actually went on
        // the wire. Body itself is intentionally not dumped — once we
        // verified that prompts pass through correctly, the value is
        // user-sensitive context that doesn't need to live in the log.
        let promptLen = (payload["prompt"] as? String)?.count ?? 0
        let termsCount = (payload["terms"] as? [String])?.count ?? 0
        sessionLogger.notice("session.create model=\(model, privacy: .public) hasPrompt=\(promptLen > 0, privacy: .public) promptChars=\(promptLen, privacy: .public) termsCount=\(termsCount, privacy: .public)")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RealtimeTranscriptionError.invalidMessage
        }
        guard http.statusCode < 400 else {
            throw RealtimeTranscriptionError.httpError(statusCode: http.statusCode)
        }
        return try JSONDecoder().decode(RealtimeSessionCreateResponse.self, from: data)
    }

    nonisolated static func sessionCreatePayload(
        model: String,
        vad: Bool,
        context: RealtimeSessionContext
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "model": model,
            "vad": vad,
            "silence_duration_ms": 1200
        ]
        if let prompt = context.prompt?.trimmingCharacters(in: .whitespacesAndNewlines),
           !prompt.isEmpty {
            payload["prompt"] = prompt
        }
        if !context.terms.isEmpty {
            payload["terms"] = context.terms
        }

        return payload
    }

    private static func receiveSocketEvent(task: URLSessionWebSocketTask) async throws -> RealtimeSocketEvent {
        let message = try await task.receive()
        return try RealtimeMessageParser.parseSocketMessage(message)
    }
}

/// Internal aggregator for the WS event stream during bulk transcribe.
/// Exposed at module-internal access so `VoiceFlowKitTests` can verify
/// the finished-vs-error ordering directly. PR #34 fix lives here.
actor BulkTranscriptionProgress {
    private var transcriptValue = ""
    private var finishedValue = false
    private var receivedErrorValue: String?

    func handle(
        _ event: RealtimeTranscriptEvent,
        onPartialTranscript: (@Sendable (String) -> Void)?
    ) {
        // Once the server has reported `.status(.idle)` (transcription
        // complete) any subsequent `.disconnected` / `.error` events are
        // just the WebSocket winding down on the way home and must not
        // be treated as failures — otherwise resend reports "transcription
        // failed" right after successfully delivering the transcript.
        if finishedValue {
            if case .textDelta = event {
                // Ignore — accumulating further deltas after .idle would
                // corrupt the final value; the server already told us
                // it's done.
            }
            return
        }

        switch event {
        case .textDelta(let content, let isNewResponse):
            transcriptValue = TranscriptDeltaReducer.apply(
                current: transcriptValue,
                content: content,
                isNewResponse: isNewResponse
            )
            onPartialTranscript?(transcriptValue)
        case .status(.idle):
            finishedValue = true
        case .error(let message):
            receivedErrorValue = message
            finishedValue = true
        case .disconnected:
            receivedErrorValue = "WebSocket disconnected"
            finishedValue = true
        case .recoveryStarted, .recoveryFailed:
            break
        case .status:
            break
        }
    }

    var transcript: String {
        transcriptValue
    }

    var isFinished: Bool {
        finishedValue
    }

    var receivedError: String? {
        receivedErrorValue
    }

    func resolvedTranscript() throws -> String {
        if let receivedErrorValue {
            throw RealtimeTranscriptionError.websocketError(receivedErrorValue)
        }
        guard finishedValue else {
            throw RealtimeTranscriptionError.connectionLost("Timed out waiting for transcription to finish")
        }
        let trimmed = transcriptValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RealtimeTranscriptionError.emptyTranscript
        }
        return trimmed
    }
}

final actor MockRealtimeTranscriptionClient: RealtimeTranscribing {
    public var liveResult: Result<String, Error>
    public var bulkResult: Result<String, Error>
    private var appendedChunkCountValue = 0
    private var appendedPCM = Data()
    private var didFinalizeValue = false
    private var didCancelValue = false
    private var appendedByteCountAtFinalizeValue = 0
    private var bulkCallCountValue = 0
    private var liveFinalizeDelayMilliseconds: UInt64 = 0
    private var bulkDelayMilliseconds: UInt64 = 0
    private var liveEventHandler: (@Sendable (RealtimeTranscriptEvent) -> Void)?
    private var liveOnEvent: (@Sendable (RealtimeTranscriptEvent) -> Void)?
    private var livePhase: RealtimeConnectionPhase = .connected
    private var liveIsFinalizing = false

    public init(
        liveResult: Result<String, Error> = .success("mock stream transcript"),
        bulkResult: Result<String, Error>? = nil
    ) {
        self.liveResult = liveResult
        self.bulkResult = bulkResult ?? liveResult
    }

    /// Mock records the last context passed in so tests can assert
    /// that prompt/terms made it through the wiring layer.
    public private(set) var lastLiveContext: RealtimeSessionContext = .empty
    public private(set) var lastBulkContext: RealtimeSessionContext = .empty
    public private(set) var lastLiveModel = ""
    public private(set) var lastBulkModel = ""
    public private(set) var lastLiveStrategy: VoiceFlowRecordingStrategy = .openAIRealtime
    public private(set) var lastBulkStrategy: VoiceFlowRecordingStrategy = .openAIRealtime

    public func beginLiveSession(
        baseURL: String,
        token: String,
        model: String,
        strategy: VoiceFlowRecordingStrategy = .openAIRealtime,
        context: RealtimeSessionContext,
        onEvent: @escaping @Sendable (RealtimeTranscriptEvent) -> Void
    ) async throws -> RealtimeLiveTranscriptionSession {
        liveEventHandler = onEvent
        liveOnEvent = onEvent
        livePhase = .connected
        liveIsFinalizing = false
        lastLiveContext = context
        lastLiveModel = model
        lastLiveStrategy = strategy
        onEvent(.status(.connected))
        return MockLiveSessionProxy(client: self)
    }

    public func emitLiveEvent(_ event: RealtimeTranscriptEvent) async {
        if liveOnEvent != nil {
            ingestLiveEvent(event)
        } else {
            liveEventHandler?(event)
        }
    }

    public func ingestLiveEvent(_ event: RealtimeTranscriptEvent) {
        switch event {
        case .textDelta:
            guard liveIsFinalizing else { return }
            liveOnEvent?(event)
        default:
            liveOnEvent?(event)
        }
    }

    public func liveConnectionPhase() -> RealtimeConnectionPhase {
        livePhase
    }

    public func setLivePhase(_ phase: RealtimeConnectionPhase) {
        livePhase = phase
    }

    public func setLiveFinalizing(_ isFinalizing: Bool) {
        liveIsFinalizing = isFinalizing
    }

    public func transcribeBulkPCM(
        pcmData: Data,
        baseURL: String,
        token: String,
        model: String,
        strategy: VoiceFlowRecordingStrategy = .openAIRealtime,
        context: RealtimeSessionContext,
        onPartialTranscript: (@Sendable (String) -> Void)?
    ) async throws -> String {
        bulkCallCountValue += 1
        lastBulkContext = context
        lastBulkModel = model
        lastBulkStrategy = strategy
        if bulkDelayMilliseconds > 0 {
            try await Task.sleep(for: .milliseconds(bulkDelayMilliseconds))
        }
        let text = try bulkResult.get()
        onPartialTranscript?(text)
        onPartialTranscript?(text)
        return text
    }

    public func recordAppendedChunk(_ chunk: Data) {
        appendedChunkCountValue += 1
        appendedPCM.append(chunk)
    }

    public func preservedAudioFromAppendedChunks() throws -> VoiceFlowPreservedAudio? {
        guard !appendedPCM.isEmpty else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voiceflow-stub-preserved-\(UUID().uuidString).pcm")
        try appendedPCM.write(to: url)
        return VoiceFlowPreservedAudio(
            fileURL: url,
            byteCount: appendedPCM.count,
            strategy: lastLiveStrategy,
            model: lastLiveModel
        )
    }

    public func markCancelled() {
        didCancelValue = true
    }

    public func markFinalized() {
        didFinalizeValue = true
        appendedByteCountAtFinalizeValue = appendedPCM.count
    }

    public func waitForLiveFinalizeDelay() async throws {
        if liveFinalizeDelayMilliseconds > 0 {
            try await Task.sleep(for: .milliseconds(liveFinalizeDelayMilliseconds))
        }
    }

    public func setLiveFinalizeDelay(milliseconds: UInt64) {
        liveFinalizeDelayMilliseconds = milliseconds
    }

    public func setBulkDelay(milliseconds: UInt64) {
        bulkDelayMilliseconds = milliseconds
    }

    public func simulateFinalize(onEvent: @escaping @Sendable (RealtimeTranscriptEvent) -> Void) throws -> String {
        didFinalizeValue = true
        let text = try liveResult.get()
        onEvent(.textDelta(content: text, isNewResponse: true))
        onEvent(.status(.idle))
        return text
    }

    public func resolvedLiveTranscript() throws -> String {
        try liveResult.get()
    }

    public func setBulkResult(_ result: Result<String, Error>) {
        bulkResult = result
    }

    public var appendedChunkCount: Int {
        appendedChunkCountValue
    }

    public var appendedPCMData: Data {
        appendedPCM
    }

    public var appendedByteCountAtFinalize: Int {
        appendedByteCountAtFinalizeValue
    }

    public var bulkCallCount: Int {
        bulkCallCountValue
    }

    public var didFinalize: Bool {
        didFinalizeValue
    }

    public var didCancel: Bool {
        didCancelValue
    }
}

private nonisolated struct MockLiveSessionProxy: RealtimeLiveTranscriptionSession {
    let client: MockRealtimeTranscriptionClient

    var connectionPhase: RealtimeConnectionPhase {
        get async {
            await client.liveConnectionPhase()
        }
    }

    func appendAudioChunk(_ chunk: Data) async {
        await client.recordAppendedChunk(chunk)
    }

    func heartbeat() async {}

    func finalize(onPartialTranscript: (@Sendable (String) -> Void)?) async throws -> String {
        await client.markFinalized()
        await client.setLiveFinalizing(true)
        await client.setLivePhase(.generating)
        try await client.waitForLiveFinalizeDelay()
        let text = try await client.resolvedLiveTranscript()
        await client.ingestLiveEvent(.textDelta(content: text, isNewResponse: true))
        await client.ingestLiveEvent(.status(.idle))
        onPartialTranscript?(text)
        await client.setLiveFinalizing(false)
        await client.setLivePhase(.disconnected)
        return text
    }

    func cancel() async {
        await client.markCancelled()
        await client.setLivePhase(.disconnected)
    }

    func abortPreservingAudio() async throws -> VoiceFlowPreservedAudio? {
        await client.markCancelled()
        await client.setLivePhase(.disconnected)
        return try await client.preservedAudioFromAppendedChunks()
    }
}
