import Foundation

protocol RealtimeTranscribing: Sendable {
    func beginLiveSession(
        baseURL: String,
        token: String,
        model: String,
        onEvent: @escaping @Sendable (RealtimeTranscriptEvent) -> Void
    ) async throws -> RealtimeLiveTranscriptionSession

    func transcribeBulkPCM(
        pcmData: Data,
        baseURL: String,
        token: String,
        model: String,
        onPartialTranscript: (@Sendable (String) -> Void)?
    ) async throws -> String
}

protocol RealtimeLiveTranscriptionSession: Sendable {
    func appendAudioChunk(_ chunk: Data) async
    func heartbeat() async
    func finalize(onPartialTranscript: (@Sendable (String) -> Void)?) async throws
    func cancel() async
    var connectionPhase: RealtimeConnectionPhase { get async }
}

actor RealtimeTranscriptionSession {
    private let webSocketTask: URLSessionWebSocketTask
    private let urlSession: URLSession
    private let sender: RealtimeWebSocketSender
    private let onEvent: @Sendable (RealtimeTranscriptEvent) -> Void
    private var receiveTask: Task<Void, Never>?
    private var isClosed = false
    private var hasSentCommit = false
    private var shouldSendStopAfterTranscriptCompleted = false
    private var enqueuedAudioBytes = 0

    init(
        webSocketTask: URLSessionWebSocketTask,
        urlSession: URLSession,
        onEvent: @escaping @Sendable (RealtimeTranscriptEvent) -> Void
    ) {
        self.webSocketTask = webSocketTask
        self.urlSession = urlSession
        self.sender = RealtimeWebSocketSender(task: webSocketTask)
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
        shouldSendStopAfterTranscriptCompleted = true
        try await sender.send(.string(RealtimeTranscriptionConfig.commitMessage))
    }

    func sendStop() async throws {
        guard !isClosed else { return }
        try await sender.send(.string(RealtimeTranscriptionConfig.stopMessage))
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

    func close() {
        guard !isClosed else { return }
        isClosed = true
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask.cancel(with: .goingAway, reason: nil)
        urlSession.invalidateAndCancel()
        onEvent(.disconnected)
    }

    private func receiveLoop() async {
        while !Task.isCancelled, !isClosed {
            do {
                let message = try await webSocketTask.receive()
                let socketEvent = try RealtimeMessageParser.parseSocketMessage(message)
                if socketEvent.type == "transcript_completed", shouldSendStopAfterTranscriptCompleted {
                    shouldSendStopAfterTranscriptCompleted = false
                    try? await sender.send(.string(RealtimeTranscriptionConfig.stopMessage))
                }
                if let event = RealtimeMessageParser.parseSocketEvent(socketEvent) {
                    onEvent(event)
                }
            } catch {
                if !Task.isCancelled, !isClosed {
                    onEvent(.disconnected)
                }
                break
            }
        }
    }
}

actor RealtimeLiveSessionHandle: RealtimeLiveTranscriptionSession {
    private let cache: AudioChunkCache
    private let makeSession: @Sendable () async throws -> RealtimeTranscriptionSession
    private let onEvent: @Sendable (RealtimeTranscriptEvent) -> Void
    private var session: RealtimeTranscriptionSession?
    private var isRecovering = false
    private var phase: RealtimeConnectionPhase = .connecting
    private var isFinalizing = false
    private var finalizeContinuation: CheckedContinuation<Void, Error>?
    private var finalizeTranscriptAccumulator = ""
    private var finalizePartialCallback: (@Sendable (String) -> Void)?

    init(
        cache: AudioChunkCache,
        onEvent: @escaping @Sendable (RealtimeTranscriptEvent) -> Void,
        makeSession: @escaping @Sendable () async throws -> RealtimeTranscriptionSession
    ) {
        self.cache = cache
        self.onEvent = onEvent
        self.makeSession = makeSession
    }

    var connectionPhase: RealtimeConnectionPhase {
        phase
    }

    func attachInitialSession(_ newSession: RealtimeTranscriptionSession) async throws {
        guard session == nil, !isRecovering else {
            await newSession.close()
            return
        }
        isRecovering = true
        phase = .recovering
        defer {
            isRecovering = false
            if case .recovering = phase {
                phase = .connected
            }
        }
        try await replayCache(to: newSession)
        session = newSession
        phase = .connected
    }

    func appendAudioChunk(_ chunk: Data) async {
        do {
            try cache.append(chunk)
            guard !isRecovering, let session else { return }
            try await session.sendAudioChunk(chunk)
        } catch {
            await recover(reason: error)
        }
    }

    func heartbeat() async {
        guard !isRecovering, let session else { return }
        do {
            try await session.ping()
        } catch {
            await recover(reason: error)
        }
    }

    func finalize(onPartialTranscript: (@Sendable (String) -> Void)? = nil) async throws {
        isFinalizing = true
        finalizeTranscriptAccumulator = ""
        finalizePartialCallback = onPartialTranscript
        phase = .generating
        defer {
            isFinalizing = false
            finalizeContinuation = nil
            finalizePartialCallback = nil
            finalizeTranscriptAccumulator = ""
        }

        let maxAttempts = 2
        var lastError: Error = RealtimeTranscriptionError.emptyTranscript

        for attempt in 0..<maxAttempts {
            try await ensureSessionReadyForFinalize()
            guard var activeSession = session else {
                throw RealtimeTranscriptionError.sessionUnavailable
            }

            if cache.byteCount >= RealtimeTranscriptionConfig.minCommitAudioBytes,
               await activeSession.pendingCommitAudioBytes < RealtimeTranscriptionConfig.minCommitAudioBytes {
                await recover(reason: RealtimeTranscriptionError.connectionLost("Audio not fully synced before finalize"))
                try await ensureSessionReadyForFinalize()
                guard let recoveredSession = session else {
                    throw RealtimeTranscriptionError.sessionUnavailable
                }
                activeSession = recoveredSession
            }

            finalizeTranscriptAccumulator = ""
            do {
                try await waitForFinalizeResult {
                    try await activeSession.sendCommit()
                }
                let trimmed = finalizeTranscriptAccumulator.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return
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
        while isRecovering {
            try await Task.sleep(for: .milliseconds(100))
        }
        if session == nil {
            await recover(reason: RealtimeTranscriptionError.connectionLost("Session unavailable before finalize"))
        }
        while isRecovering {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard session != nil else {
            throw RealtimeTranscriptionError.sessionUnavailable
        }
    }

    private func waitForFinalizeResult(sendCommit: () async throws -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await self.waitForFinalizeSignal()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(30))
                throw RealtimeTranscriptionError.connectionLost("Timed out waiting for transcription to finish")
            }
            try await sendCommit()
            try await group.next()
            group.cancelAll()
        }
    }

    private func waitForFinalizeSignal() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            finalizeContinuation = continuation
        }
    }

    func ingestServerEvent(_ event: RealtimeTranscriptEvent) {
        handleServerEvent(event)
    }

    func shouldNotifyUI(for event: RealtimeTranscriptEvent) -> Bool {
        switch event {
        case .textDelta:
            return isFinalizing
        case .error(let message):
            return isFinalizing || !RealtimeTranscriptionSupport.isRecoverableBufferTooSmallError(message)
        default:
            return true
        }
    }

    private func completeFinalize(with result: Result<Void, Error>) {
        guard let continuation = finalizeContinuation else { return }
        finalizeContinuation = nil
        switch result {
        case .success:
            continuation.resume()
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    func cancel() async {
        if let session {
            await session.close()
        }
        session = nil
        cache.remove()
        phase = .disconnected
    }

    func handleServerEvent(_ event: RealtimeTranscriptEvent) {
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
                    let trimmed = finalizeTranscriptAccumulator.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty {
                        completeFinalize(with: .failure(RealtimeTranscriptionError.emptyTranscript))
                    } else {
                        completeFinalize(with: .success(()))
                    }
                }
            }
        case .disconnected:
            phase = .disconnected
            if isFinalizing {
                completeFinalize(with: .failure(RealtimeTranscriptionError.connectionLost("WebSocket disconnected")))
            } else {
                Task { await self.recover(reason: RealtimeTranscriptionError.connectionLost("WebSocket disconnected")) }
            }
        case .error(let message):
            if RealtimeTranscriptionSupport.isRecoverableBufferTooSmallError(message), !isFinalizing {
                break
            }
            if isFinalizing {
                completeFinalize(with: .failure(RealtimeTranscriptionError.websocketError(message)))
            }
        case .textDelta(let content, let isNewResponse):
            guard isFinalizing else { return }
            finalizeTranscriptAccumulator = TranscriptDeltaReducer.apply(
                current: finalizeTranscriptAccumulator,
                content: content,
                isNewResponse: isNewResponse
            )
            finalizePartialCallback?(finalizeTranscriptAccumulator)
        case .recoveryStarted, .recoveryFailed:
            break
        }
    }

    private func recover(reason: Error) async {
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

    private func replayCache(to targetSession: RealtimeTranscriptionSession) async throws {
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
    func beginLiveSession(
        baseURL: String,
        token: String,
        model: String = RealtimeTranscriptionConfig.defaultModel,
        onEvent: @escaping @Sendable (RealtimeTranscriptEvent) -> Void
    ) async throws -> RealtimeLiveTranscriptionSession {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            throw RealtimeTranscriptionError.missingToken
        }

        let cache = try AudioChunkCache()
        var handle: RealtimeLiveSessionHandle!
        handle = RealtimeLiveSessionHandle(cache: cache, onEvent: onEvent) {
            try await Self.makeSession(
                baseURL: baseURL,
                token: trimmedToken,
                model: model,
                vad: false,
                onEvent: { event in
                    Self.deliverLiveSessionEvent(event, handle: handle, onEvent: onEvent)
                }
            )
        }

        Task {
            do {
                let initialSession = try await Self.makeSession(
                    baseURL: baseURL,
                    token: trimmedToken,
                    model: model,
                    vad: false,
                    onEvent: { event in
                        Self.deliverLiveSessionEvent(event, handle: handle, onEvent: onEvent)
                    }
                )
                try await handle.attachInitialSession(initialSession)
            } catch {
                onEvent(.recoveryFailed(message: String(describing: error)))
            }
        }

        return handle
    }

    func transcribeBulkPCM(
        pcmData: Data,
        baseURL: String,
        token: String,
        model: String = RealtimeTranscriptionConfig.defaultModel,
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
            vad: false,
            onEvent: { event in
                Task {
                    await progress.handle(event, onPartialTranscript: onPartialTranscript)
                }
            }
        )

        defer { Task { await session.close() } }

        for start in stride(from: 0, to: pcmData.count, by: RealtimeTranscriptionConfig.replayChunkSize) {
            let end = min(start + RealtimeTranscriptionConfig.replayChunkSize, pcmData.count)
            try await session.sendAudioChunk(pcmData.subdata(in: start..<end))
        }

        try await session.sendCommitAndStop()

        let deadline = Date().addingTimeInterval(30)
        while !(await progress.isFinished), Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }

        if let receivedError = await progress.receivedError {
            throw RealtimeTranscriptionError.websocketError(receivedError)
        }

        let trimmed = (await progress.transcript).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RealtimeTranscriptionError.emptyTranscript
        }
        return trimmed
    }

    private static func deliverLiveSessionEvent(
        _ event: RealtimeTranscriptEvent,
        handle: RealtimeLiveSessionHandle,
        onEvent: @escaping @Sendable (RealtimeTranscriptEvent) -> Void
    ) {
        Task {
            await handle.ingestServerEvent(event)
            if await handle.shouldNotifyUI(for: event) {
                onEvent(event)
            }
        }
    }

    private static func makeSession(
        baseURL: String,
        token: String,
        model: String,
        vad: Bool = false,
        onEvent: @escaping @Sendable (RealtimeTranscriptEvent) -> Void
    ) async throws -> RealtimeTranscriptionSession {
        let normalizedBase = try RealtimeAPIURLBuilder.normalizedBaseURL(from: baseURL)
        let sessionResponse = try await createRealtimeSession(
            baseURL: normalizedBase,
            token: token,
            model: model,
            vad: vad
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
        onEvent(.status(.connected))

        let session = RealtimeTranscriptionSession(
            webSocketTask: webSocketTask,
            urlSession: urlSession,
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
        vad: Bool
    ) async throws -> RealtimeSessionCreateResponse {
        guard let url = RealtimeAPIURLBuilder.buildAPIURL(
            base: baseURL,
            path: RealtimeTranscriptionConfig.sessionCreatePath
        ) else {
            throw RealtimeTranscriptionError.invalidBaseURL
        }

        let payload: [String: Any] = [
            "model": model,
            "vad": vad,
            "silence_duration_ms": 1200
        ]

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

    private static func receiveSocketEvent(task: URLSessionWebSocketTask) async throws -> RealtimeSocketEvent {
        let message = try await task.receive()
        return try RealtimeMessageParser.parseSocketMessage(message)
    }
}

private actor BulkTranscriptionProgress {
    private var transcriptValue = ""
    private var finishedValue = false
    private var receivedErrorValue: String?

    func handle(
        _ event: RealtimeTranscriptEvent,
        onPartialTranscript: (@Sendable (String) -> Void)?
    ) {
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
}

final actor MockRealtimeTranscriptionClient: RealtimeTranscribing {
    var liveResult: Result<String, Error>
    var bulkResult: Result<String, Error>
    private var appendedChunkCountValue = 0
    private var didFinalizeValue = false
    private var didCancelValue = false
    private var liveEventHandler: (@Sendable (RealtimeTranscriptEvent) -> Void)?
    private var activeLiveSession: MockLiveSession?

    init(
        liveResult: Result<String, Error> = .success("mock stream transcript"),
        bulkResult: Result<String, Error>? = nil
    ) {
        self.liveResult = liveResult
        self.bulkResult = bulkResult ?? liveResult
    }

    func beginLiveSession(
        baseURL: String,
        token: String,
        model: String,
        onEvent: @escaping @Sendable (RealtimeTranscriptEvent) -> Void
    ) async throws -> RealtimeLiveTranscriptionSession {
        let session = MockLiveSession(client: self, onEvent: onEvent)
        liveEventHandler = onEvent
        activeLiveSession = session
        onEvent(.status(.connected))
        return session
    }

    func emitLiveEvent(_ event: RealtimeTranscriptEvent) async {
        if let session = activeLiveSession {
            await session.ingest(event)
        } else {
            liveEventHandler?(event)
        }
    }

    func transcribeBulkPCM(
        pcmData: Data,
        baseURL: String,
        token: String,
        model: String,
        onPartialTranscript: (@Sendable (String) -> Void)?
    ) async throws -> String {
        let text = try bulkResult.get()
        onPartialTranscript?(text)
        onPartialTranscript?(text)
        return text
    }

    func recordAppendedChunk() {
        appendedChunkCountValue += 1
    }

    func markCancelled() {
        didCancelValue = true
    }

    func simulateFinalize(onEvent: @escaping @Sendable (RealtimeTranscriptEvent) -> Void) throws -> String {
        didFinalizeValue = true
        let text = try liveResult.get()
        onEvent(.textDelta(content: text, isNewResponse: true))
        onEvent(.status(.idle))
        return text
    }

    func resolvedLiveTranscript() throws -> String {
        try liveResult.get()
    }

    func setBulkResult(_ result: Result<String, Error>) {
        bulkResult = result
    }

    var appendedChunkCount: Int {
        appendedChunkCountValue
    }

    var didFinalize: Bool {
        didFinalizeValue
    }

    var didCancel: Bool {
        didCancelValue
    }
}

private actor MockLiveSession: RealtimeLiveTranscriptionSession {
    private let client: MockRealtimeTranscriptionClient
    private let onEvent: @Sendable (RealtimeTranscriptEvent) -> Void
    private var phase: RealtimeConnectionPhase = .connected
    private var isFinalizing = false

    nonisolated init(client: MockRealtimeTranscriptionClient, onEvent: @escaping @Sendable (RealtimeTranscriptEvent) -> Void) {
        self.client = client
        self.onEvent = onEvent
    }

    func ingest(_ event: RealtimeTranscriptEvent) {
        switch event {
        case .textDelta:
            guard isFinalizing else { return }
            onEvent(event)
        default:
            onEvent(event)
        }
    }

    var connectionPhase: RealtimeConnectionPhase {
        phase
    }

    func appendAudioChunk(_ chunk: Data) async {
        await client.recordAppendedChunk()
    }

    func heartbeat() async {}

    func finalize(onPartialTranscript: (@Sendable (String) -> Void)?) async throws {
        isFinalizing = true
        phase = .generating
        let text = try await client.resolvedLiveTranscript()
        ingest(.textDelta(content: text, isNewResponse: true))
        ingest(.status(.idle))
        onPartialTranscript?(text)
        isFinalizing = false
        phase = .disconnected
    }

    func cancel() async {
        await client.markCancelled()
        phase = .disconnected
    }
}
