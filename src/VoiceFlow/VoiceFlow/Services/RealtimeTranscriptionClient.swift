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
        guard !chunk.isEmpty, !isClosed else { return }
        try await sender.send(.data(chunk))
    }

    func sendCommitAndStop() async throws {
        guard !hasSentCommit else { return }
        hasSentCommit = true
        try await sender.flush()
        try await sender.send(.string(RealtimeTranscriptionConfig.commitMessage))
        try await sender.send(.string(RealtimeTranscriptionConfig.stopMessage))
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
    private var session: RealtimeTranscriptionSession?
    private var isRecovering = false
    private var phase: RealtimeConnectionPhase = .connecting
    private var isFinalizing = false
    private var finalizeContinuation: CheckedContinuation<Void, Error>?

    init(
        cache: AudioChunkCache,
        makeSession: @escaping @Sendable () async throws -> RealtimeTranscriptionSession
    ) {
        self.cache = cache
        self.makeSession = makeSession
    }

    var connectionPhase: RealtimeConnectionPhase {
        phase
    }

    func attachInitialSession(_ newSession: RealtimeTranscriptionSession) async throws {
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
        phase = .generating
        defer {
            isFinalizing = false
            finalizeContinuation = nil
        }

        while isRecovering {
            try await Task.sleep(for: .milliseconds(100))
        }
        if session == nil {
            await recover(reason: RealtimeTranscriptionError.connectionLost("Session unavailable before finalize"))
        }
        while isRecovering {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard let session else {
            throw RealtimeTranscriptionError.sessionUnavailable
        }

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        Task { await self.storeFinalizeContinuation(continuation) }
                    }
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(30))
                    throw RealtimeTranscriptionError.connectionLost("Timed out waiting for transcription to finish")
                }
                group.addTask {
                    try await session.sendCommitAndStop()
                }
                try await group.next()
                group.cancelAll()
            }
        } catch {
            await recover(reason: error)
            while isRecovering {
                try await Task.sleep(for: .milliseconds(100))
            }
            guard let recoveredSession = self.session else {
                throw RealtimeTranscriptionError.sessionUnavailable
            }
            try await recoveredSession.sendCommitAndStop()
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        Task { await self.storeFinalizeContinuation(continuation) }
                    }
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(30))
                    throw RealtimeTranscriptionError.connectionLost("Timed out waiting for transcription to finish")
                }
                try await group.next()
                group.cancelAll()
            }
        }
        _ = onPartialTranscript
    }

    private func storeFinalizeContinuation(_ continuation: CheckedContinuation<Void, Error>) {
        finalizeContinuation = continuation
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
                    completeFinalize(with: .success(()))
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
            if isFinalizing {
                completeFinalize(with: .failure(RealtimeTranscriptionError.websocketError(message)))
            }
        case .textDelta:
            break
        }
    }

    private func recover(reason: Error) async {
        guard !isRecovering else { return }
        isRecovering = true
        phase = .recovering
        if let session {
            await session.close()
        }
        session = nil
        do {
            let replacement = try await makeSession()
            try await replayCache(to: replacement)
            session = replacement
            phase = .connected
        } catch {
            phase = .disconnected
        }
        isRecovering = false
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
        let handle = RealtimeLiveSessionHandle(cache: cache) {
            try await Self.makeSession(
                baseURL: baseURL,
                token: trimmedToken,
                model: model,
                onEvent: onEvent
            )
        }

        let initialSession = try await Self.makeSession(
            baseURL: baseURL,
            token: trimmedToken,
            model: model,
            onEvent: { event in
                onEvent(event)
                Task { await handle.handleServerEvent(event) }
            }
        )
        try await handle.attachInitialSession(initialSession)
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
                progress.handle(event, onPartialTranscript: onPartialTranscript)
            }
        )

        defer { Task { await session.close() } }

        for start in stride(from: 0, to: pcmData.count, by: RealtimeTranscriptionConfig.replayChunkSize) {
            let end = min(start + RealtimeTranscriptionConfig.replayChunkSize, pcmData.count)
            try await session.sendAudioChunk(pcmData.subdata(in: start..<end))
        }

        try await session.sendCommitAndStop()

        let deadline = Date().addingTimeInterval(30)
        while !progress.isFinished, Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }

        if let receivedError = progress.receivedError {
            throw RealtimeTranscriptionError.websocketError(receivedError)
        }

        let trimmed = progress.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RealtimeTranscriptionError.emptyTranscript
        }
        return trimmed
    }

    private static func makeSession(
        baseURL: String,
        token: String,
        model: String,
        vad: Bool = true,
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

private final class BulkTranscriptionProgress: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var transcriptValue = ""
    nonisolated(unsafe) private var finishedValue = false
    nonisolated(unsafe) private var receivedErrorValue: String?

    nonisolated func handle(
        _ event: RealtimeTranscriptEvent,
        onPartialTranscript: (@Sendable (String) -> Void)?
    ) {
        lock.lock()
        defer { lock.unlock() }
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
        case .status:
            break
        }
    }

    nonisolated var transcript: String {
        lock.lock()
        defer { lock.unlock() }
        return transcriptValue
    }

    nonisolated var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finishedValue
    }

    nonisolated var receivedError: String? {
        lock.lock()
        defer { lock.unlock() }
        return receivedErrorValue
    }
}

final class MockRealtimeTranscriptionClient: RealtimeTranscribing, @unchecked Sendable {
    nonisolated(unsafe) var liveResult: Result<String, Error>
    nonisolated(unsafe) var bulkResult: Result<String, Error>
    private let lock = NSLock()
    nonisolated(unsafe) private var appendedChunkCountValue = 0
    nonisolated(unsafe) private var didFinalizeValue = false
    nonisolated(unsafe) private var didCancelValue = false

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
        onEvent(.status(.connected))
        return MockLiveSession(client: self, onEvent: onEvent)
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

    nonisolated func recordAppendedChunk() {
        lock.lock()
        appendedChunkCountValue += 1
        lock.unlock()
    }

    nonisolated func markCancelled() {
        lock.lock()
        didCancelValue = true
        lock.unlock()
    }

    nonisolated func simulateFinalize(onEvent: @escaping @Sendable (RealtimeTranscriptEvent) -> Void) throws -> String {
        lock.lock()
        didFinalizeValue = true
        lock.unlock()
        let text = try liveResult.get()
        onEvent(.textDelta(content: text, isNewResponse: true))
        onEvent(.status(.idle))
        return text
    }

    nonisolated var appendedChunkCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return appendedChunkCountValue
    }

    nonisolated var didFinalize: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didFinalizeValue
    }

    nonisolated var didCancel: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didCancelValue
    }
}

private actor MockLiveSession: RealtimeLiveTranscriptionSession {
    private let client: MockRealtimeTranscriptionClient
    private let onEvent: @Sendable (RealtimeTranscriptEvent) -> Void
    private var phase: RealtimeConnectionPhase = .connected

    init(client: MockRealtimeTranscriptionClient, onEvent: @escaping @Sendable (RealtimeTranscriptEvent) -> Void) {
        self.client = client
        self.onEvent = onEvent
    }

    var connectionPhase: RealtimeConnectionPhase {
        phase
    }

    func appendAudioChunk(_ chunk: Data) async {
        client.recordAppendedChunk()
    }

    func heartbeat() async {}

    func finalize(onPartialTranscript: (@Sendable (String) -> Void)?) async throws {
        phase = .generating
        let text = try client.simulateFinalize(onEvent: onEvent)
        onPartialTranscript?(text)
        phase = .disconnected
    }

    func cancel() async {
        client.markCancelled()
        phase = .disconnected
    }
}
