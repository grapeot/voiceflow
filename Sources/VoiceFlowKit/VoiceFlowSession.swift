import Foundation

/// Public connection phase exposed by `VoiceFlowSession`. Mirrors the
/// internal `RealtimeConnectionPhase` but the host doesn't need to
/// import the internal type.
public enum VoiceFlowConnectionPhase: Sendable, Equatable {
    case connecting
    case connected
    case recovering
    case generating
    case disconnected

    init(_ phase: RealtimeConnectionPhase) {
        switch phase {
        case .connecting:   self = .connecting
        case .connected:    self = .connected
        case .recovering:   self = .recovering
        case .generating:   self = .generating
        case .disconnected: self = .disconnected
        }
    }
}

/// Public event stream exposed by `VoiceFlowSession.events`.
public enum VoiceFlowEvent: Sendable, Equatable {
    case partialTranscript(String)
    case phaseChanged(VoiceFlowConnectionPhase)
    case recoveryStarted
    case recoveryFailed(message: String)
}

/// A realtime transcription session. Push PCM chunks, optionally ping,
/// then `commitAndStop` to finalize. The session takes care of WS
/// reconnect + cache replay internally — `sendAudioChunk` never throws
/// because of network blips; it throws only if the session is already
/// cancelled or the disk cache write fails.
///
/// `commitAndStop` returns the full transcript. The optional callback
/// fires repeatedly as partial deltas arrive during finalize.
public actor VoiceFlowSession {
    private let underlying: any RealtimeLiveTranscriptionSession
    private let eventBridge: SessionEventBridge

    init(underlying: any RealtimeLiveTranscriptionSession, eventBridge: SessionEventBridge) {
        self.underlying = underlying
        self.eventBridge = eventBridge
    }

    /// Push a PCM16/24kHz/mono chunk. Library buffers internally;
    /// network state is hidden from the caller.
    public func sendAudioChunk(_ chunk: Data) async {
        await underlying.appendAudioChunk(chunk)
    }

    /// Send a WebSocket ping. Host schedules cadence (VoiceFlow uses 12s).
    public func ping() async {
        await underlying.heartbeat()
    }

    /// Commit the audio buffer, wait for `session_stopped`, return final
    /// transcript. `onPartialTranscript` fires with the accumulated text
    /// as deltas arrive.
    public func commitAndStop(
        onPartialTranscript: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        do {
            return try await underlying.finalize(onPartialTranscript: onPartialTranscript)
        } catch let realtime as RealtimeTranscriptionError {
            throw VoiceFlowError(realtime)
        }
    }

    /// Cancel without committing. Idempotent.
    public func cancel() async {
        await underlying.cancel()
    }

    /// Current connection phase (host uses this to drive UI).
    public var connectionPhase: VoiceFlowConnectionPhase {
        get async {
            VoiceFlowConnectionPhase(await underlying.connectionPhase)
        }
    }

    /// Reactive event stream. Equivalent to the callback API; both can be
    /// used. AsyncStream is cold — start iterating before the session is
    /// active to catch all events.
    public var events: AsyncStream<VoiceFlowEvent> {
        eventBridge.stream
    }
}

/// Bridges internal `RealtimeTranscriptEvent` callbacks into the public
/// `AsyncStream<VoiceFlowEvent>`. The kit holds one bridge per session.
final class SessionEventBridge: @unchecked Sendable {
    let stream: AsyncStream<VoiceFlowEvent>
    private let continuation: AsyncStream<VoiceFlowEvent>.Continuation

    init() {
        var capturedContinuation: AsyncStream<VoiceFlowEvent>.Continuation!
        self.stream = AsyncStream(bufferingPolicy: .bufferingNewest(16)) { continuation in
            capturedContinuation = continuation
        }
        self.continuation = capturedContinuation
    }

    func emit(_ event: RealtimeTranscriptEvent) {
        switch event {
        case .textDelta(let content, _):
            continuation.yield(.partialTranscript(content))
        case .status(let status):
            switch status {
            case .connected:
                continuation.yield(.phaseChanged(.connected))
            case .connecting:
                continuation.yield(.phaseChanged(.connecting))
            case .generating:
                continuation.yield(.phaseChanged(.generating))
            case .idle:
                continuation.yield(.phaseChanged(.disconnected))
            }
        case .recoveryStarted:
            continuation.yield(.recoveryStarted)
            continuation.yield(.phaseChanged(.recovering))
        case .recoveryFailed(let message):
            continuation.yield(.recoveryFailed(message: message))
            continuation.yield(.phaseChanged(.disconnected))
        case .error(let message):
            continuation.yield(.recoveryFailed(message: message))
        case .disconnected:
            continuation.yield(.phaseChanged(.disconnected))
        }
    }

    func finish() {
        continuation.finish()
    }
}
