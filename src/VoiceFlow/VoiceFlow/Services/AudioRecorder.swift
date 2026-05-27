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
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try session.setPreferredSampleRate(48_000)
        try session.setPreferredInputNumberOfChannels(1)
        try session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

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

        let recorder = try AVAudioRecorder(url: outputURL, settings: settings)
        recorder.delegate = self
        recorder.prepareToRecord()
        guard recorder.record() else {
            throw AudioRecorderError.recordingDidNotStart
        }

        self.recorder = recorder
        self.recordingURL = outputURL
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
    private(set) var didStart = false
    private(set) var didStop = false

    init(permissionGranted: Bool = true, outputURL: URL = FileManager.default.temporaryDirectory.appendingPathComponent("voiceflow-ui-test.wav")) {
        self.permissionGranted = permissionGranted
        self.outputURL = outputURL
    }

    func requestPermission() async -> Bool {
        permissionGranted
    }

    func startRecording() async throws {
        didStart = true
    }

    func stopRecording() async throws -> URL {
        didStop = true
        return outputURL
    }

    func discardRecording() {}
}
