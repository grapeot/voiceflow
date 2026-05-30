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

    func preserveForRetry() -> String {
        resolvedText
    }

    mutating func restoreAfterRetry(_ text: String) {
        partialText = text
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
        context: RealtimeSessionContext,
        onEvent: @escaping @Sendable (RealtimeTranscriptEvent) -> Void
    ) async throws -> RealtimeLiveTranscriptionSession

    func transcribeBulkPCM(
        pcmData: Data,
        baseURL: String,
        token: String,
        model: String,
        context: RealtimeSessionContext,
        onPartialTranscript: (@Sendable (String) -> Void)?
    ) async throws -> String
}

protocol RealtimeLiveTranscriptionSession: Sendable {
    func appendAudioChunk(_ chunk: Data) async
    func heartbeat() async
    func finalize(onPartialTranscript: (@Sendable (String) -> Void)?) async throws -> String
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
    private var finalizeText = FinalizeTranscriptAccumulator()
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

    func finalize(onPartialTranscript: (@Sendable (String) -> Void)? = nil) async throws -> String {
        isFinalizing = true
        finalizeText.reset()
        finalizePartialCallback = onPartialTranscript
        phase = .generating
        defer {
            isFinalizing = false
            finalizeContinuation = nil
            finalizePartialCallback = nil
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

            do {
                try await waitForFinalizeResult {
                    try await activeSession.sendCommit()
                }
                let resolved = finalizeText.resolvedText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !resolved.isEmpty {
                    return finalizeText.resolvedText
                }
                lastError = RealtimeTranscriptionError.emptyTranscript
            } catch {
                lastError = error
            }

            if attempt < maxAttempts - 1 {
                let preserved = finalizeText.preserveForRetry()
                await recover(reason: lastError)
                if !preserved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    finalizeText.restoreAfterRetry(preserved)
                }
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
                    let trimmed = finalizeText.resolvedText.trimmingCharacters(in: .whitespacesAndNewlines)
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
            guard isFinalizing, !content.isEmpty else { return }
            if isNewResponse {
                finalizeText.setCompleted(content)
            } else {
                finalizeText.appendDelta(content)
            }
            finalizePartialCallback?(finalizeText.resolvedText)
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
    public init() {}

    public func beginLiveSession(
        baseURL: String,
        token: String,
        model: String = RealtimeTranscriptionConfig.defaultModel,
        context: RealtimeSessionContext = .empty,
        onEvent: @escaping @Sendable (RealtimeTranscriptEvent) -> Void
    ) async throws -> RealtimeLiveTranscriptionSession {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            throw RealtimeTranscriptionError.missingToken
        }

        let cache = try AudioChunkCache()
        let handleBox = LiveSessionHandleBox()
        let handle = RealtimeLiveSessionHandle(cache: cache, onEvent: onEvent) {
            try await Self.makeSession(
                baseURL: baseURL,
                token: trimmedToken,
                model: model,
                vad: false,
                context: context,
                onEvent: { event in
                    guard let boundHandle = handleBox.handle else { return }
                    Self.deliverLiveSessionEvent(event, handle: boundHandle, onEvent: onEvent)
                }
            )
        }
        handleBox.handle = handle

        Task {
            do {
                let initialSession = try await Self.makeSession(
                    baseURL: baseURL,
                    token: trimmedToken,
                    model: model,
                    vad: false,
                    context: context,
                    onEvent: { event in
                        guard let boundHandle = handleBox.handle else { return }
                        Self.deliverLiveSessionEvent(event, handle: boundHandle, onEvent: onEvent)
                    }
                )
                try await handle.attachInitialSession(initialSession)
            } catch {
                onEvent(.recoveryFailed(message: String(describing: error)))
            }
        }

        return handle
    }

    public func transcribeBulkPCM(
        pcmData: Data,
        baseURL: String,
        token: String,
        model: String = RealtimeTranscriptionConfig.defaultModel,
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
            vad: false,
            context: context,
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

    nonisolated private static func deliverLiveSessionEvent(
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
        context: RealtimeSessionContext = .empty,
        onEvent: @escaping @Sendable (RealtimeTranscriptEvent) -> Void
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
        vad: Bool,
        context: RealtimeSessionContext
    ) async throws -> RealtimeSessionCreateResponse {
        guard let url = RealtimeAPIURLBuilder.buildAPIURL(
            base: baseURL,
            path: RealtimeTranscriptionConfig.sessionCreatePath
        ) else {
            throw RealtimeTranscriptionError.invalidBaseURL
        }

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
}

final actor MockRealtimeTranscriptionClient: RealtimeTranscribing {
    public var liveResult: Result<String, Error>
    public var bulkResult: Result<String, Error>
    private var appendedChunkCountValue = 0
    private var didFinalizeValue = false
    private var didCancelValue = false
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

    public func beginLiveSession(
        baseURL: String,
        token: String,
        model: String,
        context: RealtimeSessionContext,
        onEvent: @escaping @Sendable (RealtimeTranscriptEvent) -> Void
    ) async throws -> RealtimeLiveTranscriptionSession {
        liveEventHandler = onEvent
        liveOnEvent = onEvent
        livePhase = .connected
        liveIsFinalizing = false
        lastLiveContext = context
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
        context: RealtimeSessionContext,
        onPartialTranscript: (@Sendable (String) -> Void)?
    ) async throws -> String {
        lastBulkContext = context
        let text = try bulkResult.get()
        onPartialTranscript?(text)
        onPartialTranscript?(text)
        return text
    }

    public func recordAppendedChunk() {
        appendedChunkCountValue += 1
    }

    public func markCancelled() {
        didCancelValue = true
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
        await client.recordAppendedChunk()
    }

    func heartbeat() async {}

    func finalize(onPartialTranscript: (@Sendable (String) -> Void)?) async throws -> String {
        await client.setLiveFinalizing(true)
        await client.setLivePhase(.generating)
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
}
