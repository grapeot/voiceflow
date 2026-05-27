import AVFoundation
import Foundation

protocol AudioRecording {
    func requestPermission() async -> Bool
    func startRecording() async throws
    func stopRecording() async throws -> URL
    func discardRecording()
}

enum AudioRecorderError: Error {
    case couldNotCreateRecorder
    case recordingDidNotStart
    case noActiveRecording
    case sessionSetupFailed(phase: SessionSetupPhase, underlying: NSError)

    enum SessionSetupPhase: String {
        case setCategory
        case setActive
        case createRecorder
    }

    var diagnosticMetadata: [String: String] {
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

final class AudioRecorder: NSObject, AudioRecording, AVAudioRecorderDelegate {
    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?

    func requestPermission() async -> Bool {
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

    func startRecording() async throws {
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
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let recorder = try performSessionSetup(phase: .createRecorder) {
            try AVAudioRecorder(url: outputURL, settings: settings)
        }
        recorder.delegate = self
        recorder.prepareToRecord()
        guard recorder.record() else {
            throw AudioRecorderError.recordingDidNotStart
        }

        self.recorder = recorder
        self.recordingURL = outputURL
    }

    private func applySessionPreferences(_ session: AVAudioSession) {
        // Preferences are best-effort; hardware may reject mono input (-50 paramErr).
        try? session.setPreferredSampleRate(48_000)
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

    func stopRecording() async throws -> URL {
        guard let recorder, let recordingURL else {
            throw AudioRecorderError.noActiveRecording
        }

        recorder.stop()
        self.recorder = nil
        self.recordingURL = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return recordingURL
    }

    func discardRecording() {
        recorder?.stop()
        recorder = nil
        if let recordingURL {
            try? FileManager.default.removeItem(at: recordingURL)
        }
        recordingURL = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

final class MockAudioRecorder: AudioRecording {
    var permissionGranted: Bool
    var outputURL: URL
    var startError: Error?
    var stopError: Error?
    private(set) var didStart = false
    private(set) var didStop = false

    init(
        permissionGranted: Bool = true,
        outputURL: URL = FileManager.default.temporaryDirectory.appendingPathComponent("voiceflow-ui-test.wav"),
        startError: Error? = nil,
        stopError: Error? = nil
    ) {
        self.permissionGranted = permissionGranted
        self.outputURL = outputURL
        self.startError = startError
        self.stopError = stopError
    }

    func requestPermission() async -> Bool {
        permissionGranted
    }

    func startRecording() async throws {
        if let startError {
            throw startError
        }
        didStart = true
    }

    func stopRecording() async throws -> URL {
        if let stopError {
            throw stopError
        }
        didStop = true
        if !FileManager.default.fileExists(atPath: outputURL.path) {
            try Data("mock-audio".utf8).write(to: outputURL)
        }
        return outputURL
    }

    func discardRecording() {}
}
