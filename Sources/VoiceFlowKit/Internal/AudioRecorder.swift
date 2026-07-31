#if os(iOS) || os(visionOS)
@preconcurrency import AVFoundation
#endif
import Foundation

public protocol AudioRecording: Sendable {
    func requestPermission() async -> Bool
    func startRecording(onPCMChunk: (@Sendable (Data) -> Void)?) async throws
    func startRecording(
        strategy: VoiceFlowRecordingStrategy,
        onPCMChunk: (@Sendable (Data) -> Void)?
    ) async throws
    func stopRecording() async throws -> URL
    func discardRecording()
}

public extension AudioRecording {
    func startRecording(
        strategy: VoiceFlowRecordingStrategy,
        onPCMChunk: (@Sendable (Data) -> Void)? = nil
    ) async throws {
        guard strategy.usesRealtimeTransport else {
            throw AudioRecorderError.couldNotCreateRecorder
        }
        try await startRecording(onPCMChunk: onPCMChunk)
    }
}

public enum AudioRecorderError: Error {
    case couldNotCreateRecorder
    case recordingDidNotStart
    case noActiveRecording
    case sessionSetupFailed(phase: SessionSetupPhase, underlying: NSError)

    public enum SessionSetupPhase: String {
        case setCategory
        case setActive
        case createRecorder
        case startEngine
        case finalizeRecording
    }

    public var diagnosticMetadata: [String: String] {
        switch self {
        case .sessionSetupFailed(let phase, let underlying):
            return [
                "phase": phase.rawValue,
                "errorDomain": underlying.domain,
                "errorCode": String(underlying.code)
            ]
        case .recordingDidNotStart:
            return ["phase": "beginRecording"]
        case .couldNotCreateRecorder:
            return ["phase": "createRecorder"]
        case .noActiveRecording:
            return ["phase": "stopRecording"]
        }
    }
}

final class AudioTapCallbackDeliveryCoordinator: @unchecked Sendable {
    final class Lease: @unchecked Sendable {
        private let lock = NSLock()
        private var isCompleted = false
        private let coordinator: AudioTapCallbackDeliveryCoordinator

        fileprivate init(coordinator: AudioTapCallbackDeliveryCoordinator) {
            self.coordinator = coordinator
        }

        func deliver(_ data: Data, using delivery: @escaping @Sendable (Data) -> Void) {
            guard claimCompletion() else { return }
            coordinator.enqueueDelivery(data, using: delivery)
        }

        func complete() {
            guard claimCompletion() else { return }
            coordinator.completeCallback()
        }

        private func claimCompletion() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !isCompleted else { return false }
            isCompleted = true
            return true
        }
    }

    private let lock = NSLock()
    private let deliveryQueue = DispatchQueue(label: "ai.yage.voiceflow.pcm-callback-delivery")
    private var isAcceptingCallbacks = true
    private var pendingCallbackCount = 0
    private var finishWaiters: [@Sendable () -> Void] = []

    func beginCallback() -> Lease? {
        lock.lock()
        defer { lock.unlock() }
        guard isAcceptingCallbacks else { return nil }
        pendingCallbackCount += 1
        return Lease(coordinator: self)
    }

    func finish() async {
        await withCheckedContinuation { continuation in
            closeAndNotifyWhenDrained {
                continuation.resume()
            }
        }
    }

    func finishBlocking() {
        let semaphore = DispatchSemaphore(value: 0)
        closeAndNotifyWhenDrained {
            semaphore.signal()
        }
        semaphore.wait()
    }

    private func enqueueDelivery(
        _ data: Data,
        using delivery: @escaping @Sendable (Data) -> Void
    ) {
        deliveryQueue.async { [self] in
            delivery(data)
            completeCallback()
        }
    }

    private func completeCallback() {
        let waiters: [@Sendable () -> Void]
        lock.lock()
        pendingCallbackCount -= 1
        if pendingCallbackCount == 0, !isAcceptingCallbacks {
            waiters = finishWaiters
            finishWaiters.removeAll()
        } else {
            waiters = []
        }
        lock.unlock()
        waiters.forEach { $0() }
    }

    private func closeAndNotifyWhenDrained(_ waiter: @escaping @Sendable () -> Void) {
        let shouldNotifyImmediately: Bool
        lock.lock()
        isAcceptingCallbacks = false
        if pendingCallbackCount == 0 {
            shouldNotifyImmediately = true
        } else {
            shouldNotifyImmediately = false
            finishWaiters.append(waiter)
        }
        lock.unlock()
        if shouldNotifyImmediately {
            waiter()
        }
    }
}

#if os(iOS) || os(visionOS)
public final class AudioRecorder: NSObject, AudioRecording, AVAudioRecorderDelegate {
    private var audioEngine: AVAudioEngine?
    private var recordingURL: URL?
    private var pcmBuffer = Data()
    private var onPCMChunk: (@Sendable (Data) -> Void)?
    private var isRecording = false
    private var recordingStrategy: VoiceFlowRecordingStrategy = .openAIRealtime
    private var aacWriter: AACRecordingWriter?
    private var callbackDelivery: AudioTapCallbackDeliveryCoordinator?

    public override init() {
        super.init()
    }

    public func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            if #available(iOS 17.0, visionOS 1.0, *) {
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    public func startRecording(onPCMChunk: (@Sendable (Data) -> Void)? = nil) async throws {
        try await startRecording(strategy: .openAIRealtime, onPCMChunk: onPCMChunk)
    }

    public func startRecording(
        strategy: VoiceFlowRecordingStrategy,
        onPCMChunk: (@Sendable (Data) -> Void)? = nil
    ) async throws {
        self.onPCMChunk = onPCMChunk
        self.recordingStrategy = strategy
        pcmBuffer.removeAll(keepingCapacity: false)

        let session = AVAudioSession.sharedInstance()
        try performSessionSetup(phase: .setCategory) {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        }
        applySessionPreferences(session)
        try performSessionSetup(phase: .setActive) {
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(strategy == .grokBatch ? "m4a" : "wav")
        recordingURL = outputURL

        if strategy == .grokBatch {
            try performSessionSetup(phase: .createRecorder) {
                aacWriter = try AACRecordingWriter(outputURL: outputURL)
            }
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        let callbackDelivery = AudioTapCallbackDeliveryCoordinator()
        self.callbackDelivery = callbackDelivery
        let targetSampleRate = RealtimeTranscriptionConfig.sampleRate
        guard let recordingFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: recordingFormat) else {
            throw AudioRecorderError.couldNotCreateRecorder
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self, callbackDelivery] buffer, _ in
            guard let callbackLease = callbackDelivery.beginCallback() else { return }
            defer { callbackLease.complete() }
            guard let self else { return }
            let frameCount = AVAudioFrameCount(buffer.frameLength)
            let ratio = recordingFormat.sampleRate / inputFormat.sampleRate
            let capacity = AVAudioFrameCount((Double(frameCount) * ratio).rounded(.up))
            guard capacity > 0,
                  let convertedBuffer = AVAudioPCMBuffer(pcmFormat: recordingFormat, frameCapacity: capacity) else {
                return
            }

            var error: NSError?
            nonisolated(unsafe) let capturedBuffer = buffer
            let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                outStatus.pointee = .haveData
                return capturedBuffer
            }
            converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputBlock)

            guard let channelData = convertedBuffer.int16ChannelData?[0] else { return }
            let bufferLength = Int(convertedBuffer.frameLength)
            let bytesPerFrame = Int(recordingFormat.streamDescription.pointee.mBytesPerFrame)
            let data = Data(bytes: channelData, count: bufferLength * bytesPerFrame)
            callbackLease.deliver(data) { [weak self] data in
                guard let self else { return }
                if strategy.usesRealtimeTransport {
                    self.pcmBuffer.append(data)
                } else {
                    self.aacWriter?.enqueue(pcmData: data)
                }
                self.onPCMChunk?(data)
            }
        }

        try performSessionSetup(phase: .startEngine) {
            try engine.start()
        }

        audioEngine = engine
        isRecording = true
    }

    private func applySessionPreferences(_ session: AVAudioSession) {
        try? session.setPreferredSampleRate(RealtimeTranscriptionConfig.sampleRate)
        try? session.setPreferredInputNumberOfChannels(1)
        try? session.setPreferredIOBufferDuration(0.02)
    }

    private func performSessionSetup<T>(
        phase: AudioRecorderError.SessionSetupPhase,
        operation: () throws -> T
    ) throws -> T {
        do {
            return try operation()
        } catch let error as AudioRecorderError {
            throw error
        } catch {
            throw AudioRecorderError.sessionSetupFailed(phase: phase, underlying: error as NSError)
        }
    }

    public func stopRecording() async throws -> URL {
        guard isRecording, let recordingURL else {
            throw AudioRecorderError.noActiveRecording
        }

        if let engine = audioEngine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        audioEngine = nil
        isRecording = false
        await callbackDelivery?.finish()
        callbackDelivery = nil
        onPCMChunk = nil

        if recordingStrategy == .grokBatch {
            do {
                try aacWriter?.finish()
            } catch {
                aacWriter?.discard()
                aacWriter = nil
                pcmBuffer.removeAll(keepingCapacity: false)
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                self.recordingURL = nil
                throw AudioRecorderError.sessionSetupFailed(
                    phase: .finalizeRecording,
                    underlying: error as NSError
                )
            }
            aacWriter = nil
        } else {
            do {
                try PCM16WAVWriter.write(pcmData: pcmBuffer, to: recordingURL)
            } catch {
                pcmBuffer.removeAll(keepingCapacity: false)
                try? FileManager.default.removeItem(at: recordingURL)
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                self.recordingURL = nil
                throw AudioRecorderError.sessionSetupFailed(
                    phase: .finalizeRecording,
                    underlying: error as NSError
                )
            }
        }
        pcmBuffer.removeAll(keepingCapacity: false)

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        self.recordingURL = nil
        return recordingURL
    }

    public func discardRecording() {
        if let engine = audioEngine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        audioEngine = nil
        isRecording = false
        callbackDelivery?.finishBlocking()
        callbackDelivery = nil
        onPCMChunk = nil
        aacWriter?.discard()
        aacWriter = nil
        pcmBuffer.removeAll(keepingCapacity: false)
        if let recordingURL {
            try? FileManager.default.removeItem(at: recordingURL)
        }
        recordingURL = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
#endif

/// Test-only mock. Uses `@unchecked Sendable` because instances are
/// mutated from a single test scope; not safe for real cross-actor sharing.
public final class MockAudioRecorder: AudioRecording, @unchecked Sendable {
    public var permissionGranted: Bool
    public var outputURL: URL
    public var startError: Error?
    public var stopError: Error?
    public var outputPCMData: Data
    public var emittedPCMChunks: [Data]?
    public private(set) var didStart = false
    public private(set) var didStop = false
    public private(set) var receivedChunkHandler = false
    public private(set) var recordingStrategy: VoiceFlowRecordingStrategy = .openAIRealtime

    public init(
        permissionGranted: Bool = true,
        outputURL: URL = FileManager.default.temporaryDirectory.appendingPathComponent("voiceflow-ui-test.wav"),
        outputPCMData: Data = Data("mock-audio".utf8),
        emittedPCMChunks: [Data]? = nil,
        startError: Error? = nil,
        stopError: Error? = nil
    ) {
        self.permissionGranted = permissionGranted
        self.outputURL = outputURL
        self.outputPCMData = outputPCMData
        self.emittedPCMChunks = emittedPCMChunks
        self.startError = startError
        self.stopError = stopError
    }

    public func requestPermission() async -> Bool {
        permissionGranted
    }

    public func startRecording(onPCMChunk: (@Sendable (Data) -> Void)? = nil) async throws {
        try await startRecording(strategy: .openAIRealtime, onPCMChunk: onPCMChunk)
    }

    public func startRecording(
        strategy: VoiceFlowRecordingStrategy,
        onPCMChunk: (@Sendable (Data) -> Void)? = nil
    ) async throws {
        if let startError {
            throw startError
        }
        receivedChunkHandler = onPCMChunk != nil
        recordingStrategy = strategy
        didStart = true
        if !outputPCMData.isEmpty {
            let chunks = emittedPCMChunks ?? [Data(repeating: 0x10, count: 96_000)]
            for chunk in chunks {
                onPCMChunk?(chunk)
            }
            await Task.yield()
        }
    }

    public func stopRecording() async throws -> URL {
        if let stopError {
            throw stopError
        }
        didStop = true
        if outputPCMData.isEmpty {
            FileManager.default.createFile(atPath: outputURL.path, contents: Data())
        } else if recordingStrategy == .grokBatch {
            try outputPCMData.write(to: outputURL)
        } else {
            try PCM16WAVWriter.write(pcmData: outputPCMData, to: outputURL)
        }
        return outputURL
    }

    public func discardRecording() {}
}

#if os(iOS) || os(visionOS)
private final class AACRecordingWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ai.yage.voiceflow.aac-writer")
    private let outputURL: URL
    private var accepting = true
    private var firstError: Error?
    private var file: AVAudioFile?
    private let processingFormat: AVAudioFormat

    init(outputURL: URL) throws {
        self.outputURL = outputURL
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVAudioFileTypeKey: Int(kAudioFileM4AType),
            AVSampleRateKey: RealtimeTranscriptionConfig.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let file = try AVAudioFile(
            forWriting: outputURL,
            settings: settings,
            commonFormat: .pcmFormatInt16,
            interleaved: false
        )
        self.file = file
        self.processingFormat = file.processingFormat
    }

    func enqueue(pcmData: Data) {
        queue.async { [self] in
            guard accepting, firstError == nil else { return }
            do {
                let bytesPerFrame = Int(processingFormat.streamDescription.pointee.mBytesPerFrame)
                guard bytesPerFrame > 0 else { throw AudioRecorderError.couldNotCreateRecorder }
                let frameCount = AVAudioFrameCount(pcmData.count / bytesPerFrame)
                guard frameCount > 0,
                      let buffer = AVAudioPCMBuffer(
                        pcmFormat: processingFormat,
                        frameCapacity: frameCount
                      ),
                      let channel = buffer.int16ChannelData?[0] else {
                    throw AudioRecorderError.couldNotCreateRecorder
                }
                pcmData.copyBytes(
                    to: UnsafeMutableRawBufferPointer(
                        start: channel,
                        count: Int(frameCount) * bytesPerFrame
                    )
                )
                buffer.frameLength = frameCount
                try file?.write(from: buffer)
            } catch {
                firstError = error
            }
        }
    }

    func finish() throws {
        let writeError: Error? = queue.sync {
            accepting = false
            if #available(iOS 18.0, visionOS 2.0, *) {
                file?.close()
            }
            file = nil
            return firstError
        }
        if let writeError { throw writeError }

        let readable = try AVAudioFile(forReading: outputURL)
        guard readable.length > 0 else { throw AudioRecorderError.recordingDidNotStart }
    }

    func discard() {
        queue.sync {
            accepting = false
            if #available(iOS 18.0, visionOS 2.0, *) {
                file?.close()
            }
            file = nil
        }
        try? FileManager.default.removeItem(at: outputURL)
    }
}
#endif
