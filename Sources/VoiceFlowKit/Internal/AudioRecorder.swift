#if os(iOS) || os(visionOS)
@preconcurrency import AVFoundation
#endif
import Foundation

public protocol AudioRecording {
    func requestPermission() async -> Bool
    func startRecording(onPCMChunk: (@Sendable (Data) -> Void)?) async throws
    func stopRecording() async throws -> URL
    func discardRecording()
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

#if os(iOS) || os(visionOS)
public final class AudioRecorder: NSObject, AudioRecording, AVAudioRecorderDelegate {
    private var audioEngine: AVAudioEngine?
    private var recordingURL: URL?
    private var pcmBuffer = Data()
    private var onPCMChunk: (@Sendable (Data) -> Void)?
    private var isRecording = false

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
        self.onPCMChunk = onPCMChunk
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
            .appendingPathExtension("wav")
        recordingURL = outputURL

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        let targetSampleRate = RealtimeTranscriptionConfig.sampleRate
        guard let recordingFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: recordingFormat) else {
            throw AudioRecorderError.couldNotCreateRecorder
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
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
            self.pcmBuffer.append(data)
            self.onPCMChunk?(data)
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
        onPCMChunk = nil

        try PCM16WAVWriter.write(pcmData: pcmBuffer, to: recordingURL)
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
        onPCMChunk = nil
        pcmBuffer.removeAll(keepingCapacity: false)
        if let recordingURL {
            try? FileManager.default.removeItem(at: recordingURL)
        }
        recordingURL = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
#endif

public final class MockAudioRecorder: AudioRecording {
    public var permissionGranted: Bool
    public var outputURL: URL
    public var startError: Error?
    public var stopError: Error?
    public var outputPCMData: Data
    public private(set) var didStart = false
    public private(set) var didStop = false
    public private(set) var receivedChunkHandler = false

    public init(
        permissionGranted: Bool = true,
        outputURL: URL = FileManager.default.temporaryDirectory.appendingPathComponent("voiceflow-ui-test.wav"),
        outputPCMData: Data = Data("mock-audio".utf8),
        startError: Error? = nil,
        stopError: Error? = nil
    ) {
        self.permissionGranted = permissionGranted
        self.outputURL = outputURL
        self.outputPCMData = outputPCMData
        self.startError = startError
        self.stopError = stopError
    }

    public func requestPermission() async -> Bool {
        permissionGranted
    }

    public func startRecording(onPCMChunk: (@Sendable (Data) -> Void)? = nil) async throws {
        if let startError {
            throw startError
        }
        receivedChunkHandler = onPCMChunk != nil
        didStart = true
    }

    public func stopRecording() async throws -> URL {
        if let stopError {
            throw stopError
        }
        didStop = true
        if outputPCMData.isEmpty {
            FileManager.default.createFile(atPath: outputURL.path, contents: Data())
        } else {
            try PCM16WAVWriter.write(pcmData: outputPCMData, to: outputURL)
        }
        return outputURL
    }

    public func discardRecording() {}
}
