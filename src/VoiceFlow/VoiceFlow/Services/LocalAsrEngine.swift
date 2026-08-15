import CoreML
import Foundation
import FluidAudio
import os
import VoiceFlowKit

/// Status of the on-device Qwen3-ASR model weights shown in Settings.
enum LocalAsrModelStatus: Equatable {
    case notDownloaded
    case preparing
    case downloading(progress: Double)
    case paused
    case ready
    case failed(message: String)

    var isReady: Bool {
        self == .ready
    }

    var isInFlight: Bool {
        switch self {
        case .preparing, .downloading: true
        default: false
        }
    }
}

/// One-shot on-device transcription (Qwen3-ASR-0.6B via FluidAudio/CoreML).
/// The engine is transport-free: the app hands it the recorded WAV file and
/// gets text back. Model weights are downloaded on demand from HuggingFace
/// and cached in Application Support.
protocol LocalAsrTranscribing: Sendable {
    /// Whether the OS supports the stateful CoreML pipeline (iOS 18+).
    var isSupportedOnThisDevice: Bool { get }
    /// Cheap check: all required model files exist and look complete.
    func isModelReady() -> Bool
    /// Incomplete cache from a previous attempt — Settings should offer Resume.
    func hasResumableDownload() -> Bool
    /// Best-effort 0...1 fraction from bytes already on disk.
    func existingDownloadProgress() -> Double
    /// Download model weights (~0.7 GB for int8), skipping complete files and
    /// Range-resuming partial ones. `progress` reports on an arbitrary queue.
    func downloadModel(progress: @escaping @Sendable (LocalAsrDownloadUpdate) -> Void) async throws
    /// Transcribe a PCM16 WAV recording and return the text.
    func transcribe(audioFile: URL) async throws -> String
}

/// Real engine backed by FluidAudio's `Qwen3AsrManager` (ANE/CoreML).
struct FluidAudioLocalAsrEngine: LocalAsrTranscribing {
    private let variant: Qwen3AsrVariant

    init(variant: Qwen3AsrVariant = .int8) {
        self.variant = variant
    }

    var isSupportedOnThisDevice: Bool {
        if #available(iOS 18.0, *) {
            true
        } else {
            false
        }
    }

    func isModelReady() -> Bool {
        guard isSupportedOnThisDevice else { return false }
        if #available(iOS 18.0, *) {
            return LocalAsrModelDownloader(variant: variant).cacheIntegrity().isComplete
        }
        return false
    }

    func hasResumableDownload() -> Bool {
        if #available(iOS 18.0, *) {
            return LocalAsrModelDownloader(variant: variant).cacheIntegrity().isResumable
        }
        return false
    }

    func existingDownloadProgress() -> Double {
        if #available(iOS 18.0, *) {
            return LocalAsrModelDownloader(variant: variant).existingProgressHint()
        }
        return 0
    }

    func downloadModel(progress: @escaping @Sendable (LocalAsrDownloadUpdate) -> Void) async throws {
        guard isSupportedOnThisDevice else {
            throw LocalAsrEngineError.unsupportedDevice
        }
        if #available(iOS 18.0, *) {
            try await LocalAsrModelDownloader(variant: variant).download(progress: progress)
            return
        }
        throw LocalAsrEngineError.unsupportedDevice
    }

    func transcribe(audioFile: URL) async throws -> String {
        guard isSupportedOnThisDevice else {
            throw LocalAsrEngineError.unsupportedDevice
        }
        guard isModelReady() else {
            throw LocalAsrEngineError.modelNotDownloaded
        }
        if #available(iOS 18.0, *) {
            let samples = try AudioConverter().resampleAudioFile(audioFile)
            let manager = try await Qwen3ManagerCache.shared.loadedManager(for: variant)
            return try await manager.transcribe(audioSamples: samples, language: String?.none)
        }
        throw LocalAsrEngineError.unsupportedDevice
    }
}

/// Cache of loaded `Qwen3AsrManager` actors. The manager keeps the CoreML
/// models in memory; reusing one instance avoids reloading ~700 MB of
/// weights for every transcription.
///
/// The stateful decoder cannot use ANE on some devices (`ANECCompile` /
/// `std::bad_cast`) and crashes Metal attention on iPhone GPU
/// (`threadgroup memory exceeded`). CPU is the only safe backend.
@available(iOS 18.0, *)
private actor Qwen3ManagerCache {
    static let shared = Qwen3ManagerCache()
    private static let logger = Logger(subsystem: "ai.yage.voiceflow", category: "LocalAsr")
    private static let unitsDefaultsKey = "localAsr.qwen3.computeUnits.v2"
    private var managers: [String: Qwen3AsrManager] = [:]
    private var loadedKeys: Set<String> = []

    func loadedManager(for variant: Qwen3AsrVariant) async throws -> Qwen3AsrManager {
        let key = variant.rawValue
        if let existing = managers[key], loadedKeys.contains(key) {
            return existing
        }

        let directory = Qwen3AsrModels.defaultCacheDirectory(variant: variant)
        let manager = Qwen3AsrManager()
        do {
            try await manager.loadModels(from: directory, computeUnits: .cpuOnly)
            managers[key] = manager
            loadedKeys.insert(key)
            UserDefaults.standard.set("cpuOnly", forKey: Self.unitsDefaultsKey)
            UserDefaults.standard.removeObject(forKey: "localAsr.qwen3.computeUnits")
            Self.logger.info("Loaded Qwen3-ASR with computeUnits=cpuOnly")
            return manager
        } catch {
            managers[key] = nil
            loadedKeys.remove(key)
            Self.logger.error("Qwen3-ASR CPU load failed: \(String(describing: error), privacy: .public)")
            throw error
        }
    }
}

enum LocalAsrEngineError: Error, Equatable {
    case unsupportedDevice
    case modelNotDownloaded
    case interrupted
    case incompleteDownload
    case invalidRegistryResponse
    case downloadFailed(statusCode: Int)
}

/// Test double. `@unchecked Sendable` because instances are mutated from a
/// single test scope; not safe for real cross-actor sharing.
final class MockLocalAsrEngine: LocalAsrTranscribing, @unchecked Sendable {
    var supported = true
    var modelReady = false
    var resumable = false
    var existingProgress: Double = 0
    var downloadError: Error?
    var transcribeResult: Result<String, Error> = .success("local engine text")
    private(set) var downloadCallCount = 0
    private(set) var transcribedFiles: [URL] = []
    var downloadProgressEmitted: [LocalAsrDownloadUpdate] = []
    var downloadDelayNanos: UInt64 = 0

    var isSupportedOnThisDevice: Bool { supported }

    func isModelReady() -> Bool { modelReady }

    func hasResumableDownload() -> Bool { resumable }

    func existingDownloadProgress() -> Double { existingProgress }

    func downloadModel(progress: @escaping @Sendable (LocalAsrDownloadUpdate) -> Void) async throws {
        downloadCallCount += 1
        if let downloadError {
            throw downloadError
        }
        if downloadDelayNanos > 0 {
            try await Task.sleep(nanoseconds: downloadDelayNanos)
        }
        try Task.checkCancellation()
        for update in downloadProgressEmitted {
            progress(update)
        }
        modelReady = true
        resumable = false
    }

    func transcribe(audioFile: URL) async throws -> String {
        transcribedFiles.append(audioFile)
        switch transcribeResult {
        case .success(let text): return text
        case .failure(let error): throw error
        }
    }
}
