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
    private var hasSentStop = false

    init(
        webSocketTask: URLSessionWebSocketTask,
        urlSession: URLSession,
        onEvent: @escaping @Sendable (RealtimeTranscriptEvent) -> Void
    ) {
        self.webSocketTask = webSocketTask
        self.urlSession = urlSession
        self.sender = RealtimeWebSocketSender(task: webSocketTask)
        self.onEvent = onEvent
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    func sendStartRecording(model: String) async throws {
        let message = try RealtimeMessageParser.startRecordingMessage(model: model)
        try await sender.send(.string(message))
    }

    func sendAudioChunk(_ chunk: Data) async throws {
        guard !chunk.isEmpty, !isClosed else { return }
        try await sender.send(.data(chunk))
    }

    func sendStopRecording() async throws {
        guard !hasSentStop else { return }
        hasSentStop = true
        try await sender.flush()
        try await sender.send(.string(RealtimeMessageParser.stopRecordingMessage))
    }

    func sendStatusRequest() async throws {
        try await sender.send(.string(RealtimeMessageParser.statusRequestMessage))
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
                let event = try RealtimeMessageParser.parseMessage(message)
                onEvent(event)
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
            if phase == .recovering {
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

        phase = .generating
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        Task {
                            await self.storeFinalizeContinuation(continuation)
                        }
                    }
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(30))
                    throw RealtimeTranscriptionError.connectionLost("Timed out waiting for transcription to finish")
                }
                group.addTask {
                    try await session.sendStopRecording()
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
            try await recoveredSession.sendStopRecording()
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        Task {
                            await self.storeFinalizeContinuation(continuation)
                        }
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

        var transcript = ""
        var finished = false
        var receivedError: String?

        let session = try await Self.makeSession(
            baseURL: baseURL,
            token: token,
            model: model,
            onEvent: { event in
                switch event {
                case .textDelta(let content, let isNewResponse):
                    transcript = TranscriptDeltaReducer.apply(
                        current: transcript,
                        content: content,
                        isNewResponse: isNewResponse
                    )
                    onPartialTranscript?(transcript)
                case .status(.idle):
                    finished = true
                case .error(let message):
                    receivedError = message
                    finished = true
                case .disconnected:
                    receivedError = "WebSocket disconnected"
                    finished = true
                case .status:
                    break
                }
            }
        )

        defer { Task { await session.close() } }

        for start in stride(from: 0, to: pcmData.count, by: RealtimeTranscriptionConfig.replayChunkSize) {
            let end = min(start + RealtimeTranscriptionConfig.replayChunkSize, pcmData.count)
            try await session.sendAudioChunk(pcmData.subdata(in: start..<end))
        }

        try await session.sendStopRecording()

        let deadline = Date().addingTimeInterval(30)
        while !finished, Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }

        if let receivedError {
            throw RealtimeTranscriptionError.websocketError(receivedError)
        }

        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RealtimeTranscriptionError.emptyTranscript
        }
        return trimmed
    }

    private static func makeSession(
        baseURL: String,
        token: String,
        model: String,
        onEvent: @escaping @Sendable (RealtimeTranscriptEvent) -> Void
    ) async throws -> RealtimeTranscriptionSession {
        let websocketURL = try RealtimeWebSocketURLBuilder.websocketURL(from: baseURL)
        var request = URLRequest(url: websocketURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let urlSession = URLSession(configuration: .default)
        let webSocketTask = urlSession.webSocketTask(with: request)
        webSocketTask.resume()

        let session = RealtimeTranscriptionSession(
            webSocketTask: webSocketTask,
            urlSession: urlSession,
            onEvent: onEvent
        )
        try await session.sendStartRecording(model: model)
        return session
    }
}

final class MockRealtimeTranscriptionClient: RealtimeTranscribing, @unchecked Sendable {
    var liveResult: Result<String, Error>
    var bulkResult: Result<String, Error>
    private(set) var appendedChunkCount = 0
    private(set) var didFinalize = false
    private(set) var didCancel = false

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

    fileprivate func recordAppendedChunk() {
        appendedChunkCount += 1
    }

    fileprivate func markCancelled() {
        didCancel = true
    }

    fileprivate func simulateFinalize(onEvent: @escaping @Sendable (RealtimeTranscriptEvent) -> Void) async throws -> String {
        didFinalize = true
        let text = try liveResult.get()
        onEvent(.textDelta(content: text, isNewResponse: true))
        onEvent(.status(.idle))
        return text
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
        let text = try await client.simulateFinalize(onEvent: onEvent)
        onPartialTranscript?(text)
        phase = .disconnected
    }

    func cancel() async {
        client.markCancelled()
        phase = .disconnected
    }
}
