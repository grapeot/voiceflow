import Foundation
import FluidAudio

/// Progress snapshot for the on-device model fetch. `isPreparing` is true
/// while the HuggingFace file list is still being walked — the UI should
/// not treat a 0 fraction in that phase as a hung transfer.
struct LocalAsrDownloadUpdate: Sendable, Equatable {
    var fraction: Double
    var isPreparing: Bool
}

/// Local vs remote size → skip / HTTP Range resume / start over.
enum LocalAsrFileTransferPlan: Equatable {
    case skip
    case resume(from: Int64)
    case fresh
}

enum LocalAsrFileTransferPlanner {
    /// `remoteSize < 0` means the registry did not report a size.
    static func plan(completeSize: Int64?, partialSize: Int64, remoteSize: Int64) -> LocalAsrFileTransferPlan {
        if let completeSize {
            if remoteSize < 0 || completeSize == remoteSize {
                return .skip
            }
            return .fresh
        }
        if partialSize > 0 {
            if remoteSize >= 0, partialSize >= remoteSize {
                return .fresh
            }
            return .resume(from: partialSize)
        }
        return .fresh
    }
}

enum LocalAsrCacheIntegrity: Equatable {
    case missing
    case partial
    case complete

    var isComplete: Bool { self == .complete }
    var isResumable: Bool { self == .partial }
}

enum LocalAsrModelCache {
    static func requiredNames() -> [String] {
        [
            ModelNames.Qwen3ASR.audioEncoderFile,
            ModelNames.Qwen3ASR.decoderStatefulFile,
            ModelNames.Qwen3ASR.embeddingsFile,
            "vocab.json",
        ]
    }

    static func integrity(at directory: URL) -> LocalAsrCacheIntegrity {
        let fm = FileManager.default
        var sawAnything = false
        var allComplete = true

        for name in requiredNames() {
            let url = directory.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            let exists = fm.fileExists(atPath: url.path, isDirectory: &isDirectory)
            if !exists {
                allComplete = false
                continue
            }
            sawAnything = true
            if isDirectory.boolValue {
                if !isCompleteModelBundle(at: url) {
                    allComplete = false
                }
            } else {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                if size <= 0 {
                    allComplete = false
                }
            }
        }

        if fm.fileExists(atPath: directory.path),
           let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: nil) {
            for case let fileURL as URL in enumerator where fileURL.pathExtension == "partial" {
                sawAnything = true
                allComplete = false
                break
            }
        }

        if allComplete, sawAnything { return .complete }
        if sawAnything { return .partial }
        return .missing
    }

    /// A compiled CoreML bundle is more than an empty directory: FluidAudio's
    /// `modelsExist` only checks the top-level name, so an interrupted
    /// `.mlmodelc` would otherwise look ready.
    static func isCompleteModelBundle(at url: URL) -> Bool {
        let fm = FileManager.default
        let markers = ["coremldata.bin", "model.mil"]
        return markers.contains { marker in
            let markerURL = url.appendingPathComponent(marker)
            guard fm.fileExists(atPath: markerURL.path) else { return false }
            let size = (try? markerURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return size > 0
        }
    }

    static func existingByteCount(at directory: URL) -> Int64 {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path),
              let enumerator = fm.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
              )
        else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            total += Int64(values?.fileSize ?? 0)
        }
        return total
    }
}

/// HuggingFace fetch that writes into FluidAudio's cache directory, skips
/// complete files, and resumes interrupted ones with HTTP Range.
@available(iOS 18.0, *)
struct LocalAsrModelDownloader: Sendable {
    let variant: Qwen3AsrVariant

    init(variant: Qwen3AsrVariant = .int8) {
        self.variant = variant
    }

    var cacheDirectory: URL {
        Qwen3AsrModels.defaultCacheDirectory(variant: variant)
    }

    func cacheIntegrity() -> LocalAsrCacheIntegrity {
        LocalAsrModelCache.integrity(at: cacheDirectory)
    }

    func existingProgressHint() -> Double {
        let existing = LocalAsrModelCache.existingByteCount(at: cacheDirectory)
        let knownTotal = Self.rememberedTotalBytes(for: variant)
        guard existing > 0, knownTotal > 0 else { return 0 }
        return min(0.99, Double(existing) / Double(knownTotal))
    }

    func download(progress: @escaping @Sendable (LocalAsrDownloadUpdate) -> Void) async throws {
        progress(LocalAsrDownloadUpdate(fraction: existingProgressHint(), isPreparing: true))

        let repo = variant.repo
        let files = try await listRequiredFiles(repo: repo)
        let totalBytes = files.reduce(Int64(0)) { $0 + Int64(max(0, $1.size)) }
        if totalBytes > 0 {
            Self.rememberTotalBytes(totalBytes, for: variant)
        }

        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        var completedBytes = files.reduce(Int64(0)) { partial, file in
            let dest = localURL(for: file, repo: repo)
            if case .skip = plan(for: dest, remoteSize: Int64(file.size)) {
                return partial + Int64(max(0, file.size))
            }
            let partialSize = fileSize(at: dest.appendingPathExtension("partial")) ?? 0
            return partial + max(0, partialSize)
        }

        func report(_ extra: Int64 = 0, preparing: Bool = false) {
            let current = completedBytes + extra
            let fraction: Double
            if totalBytes > 0 {
                fraction = min(1, Double(current) / Double(totalBytes))
            } else if files.isEmpty {
                fraction = 1
            } else {
                fraction = 0
            }
            progress(LocalAsrDownloadUpdate(fraction: fraction, isPreparing: preparing))
        }

        report()

        for file in files {
            try Task.checkCancellation()
            let dest = localURL(for: file, repo: repo)
            let remoteSize = Int64(file.size)
            switch plan(for: dest, remoteSize: remoteSize) {
            case .skip:
                continue
            case .resume, .fresh:
                let written = try await downloadFile(
                    file,
                    repo: repo,
                    dest: dest,
                    remoteSize: remoteSize,
                    onDelta: { delta in report(delta) }
                )
                completedBytes += written
                report()
            }
        }

        guard LocalAsrModelCache.integrity(at: cacheDirectory).isComplete else {
            throw LocalAsrEngineError.incompleteDownload
        }
        progress(LocalAsrDownloadUpdate(fraction: 1, isPreparing: false))
    }

    // MARK: - Listing

    private struct RemoteFile {
        var path: String
        var size: Int
    }

    private func listRequiredFiles(repo: Repo) async throws -> [RemoteFile] {
        let required = Set(LocalAsrModelCache.requiredNames())
        var collected: [RemoteFile] = []
        let subPath = repo.subPath

        func shouldCollect(_ path: String) -> Bool {
            let relative = stripped(path, subPath: subPath)
            return required.contains { requiredName in
                relative == requiredName || relative.hasPrefix(requiredName + "/")
            }
        }

        func list(path: String) async throws {
            let apiPath = path.isEmpty ? "tree/main" : "tree/main/\(path)"
            let url = try ModelRegistry.apiModels(repo.remotePath, apiPath)
            var request = URLRequest(url: url, timeoutInterval: 60)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw LocalAsrEngineError.downloadFailed(statusCode: http.statusCode)
            }
            guard let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw LocalAsrEngineError.invalidRegistryResponse
            }
            for item in items {
                guard let itemPath = item["path"] as? String,
                      let type = item["type"] as? String
                else { continue }
                if type == "directory" {
                    let relative = stripped(itemPath, subPath: subPath)
                    let useful = required.contains { requiredName in
                        requiredName.hasPrefix(relative) || relative.hasPrefix(requiredName)
                    }
                    if useful {
                        try await list(path: itemPath)
                    }
                } else if type == "file", shouldCollect(itemPath) {
                    collected.append(RemoteFile(path: itemPath, size: item["size"] as? Int ?? -1))
                }
            }
        }

        try await list(path: subPath ?? "")

        let collectedNames = Set(collected.map { stripped($0.path, subPath: subPath).split(separator: "/").first.map(String.init) ?? $0.path })
        let missingAux = required.filter { name in
            !name.hasSuffix(".mlmodelc") && !collectedNames.contains(name)
        }
        if !missingAux.isEmpty {
            try await list(path: "")
            collected = collected.filter { file in
                shouldCollect(file.path)
            }
        }

        var unique: [String: RemoteFile] = [:]
        for file in collected {
            unique[file.path] = file
        }
        return unique.values.sorted { $0.path < $1.path }
    }

    // MARK: - Transfer

    private func plan(for dest: URL, remoteSize: Int64) -> LocalAsrFileTransferPlan {
        let complete = fileSize(at: dest)
        let partial = fileSize(at: dest.appendingPathExtension("partial")) ?? 0
        return LocalAsrFileTransferPlanner.plan(
            completeSize: complete,
            partialSize: partial,
            remoteSize: remoteSize
        )
    }

    private func downloadFile(
        _ file: RemoteFile,
        repo: Repo,
        dest: URL,
        remoteSize: Int64,
        onDelta: @escaping @Sendable (Int64) -> Void
    ) async throws -> Int64 {
        let fm = FileManager.default
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)

        let decided = plan(for: dest, remoteSize: remoteSize)
        if case .fresh = decided {
            try? fm.removeItem(at: dest)
            try? fm.removeItem(at: dest.appendingPathExtension("partial"))
        }

        if file.size == 0 {
            fm.createFile(atPath: dest.path, contents: Data())
            return 0
        }

        let partialURL = dest.appendingPathExtension("partial")
        let existing = fileSize(at: partialURL) ?? 0

        let encoded = file.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file.path
        let remote = try ModelRegistry.resolveModel(repo.remotePath, encoded)
        var request = URLRequest(url: remote, timeoutInterval: 1_800)
        if existing > 0 {
            request.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range")
        }

        let (tempURL, response) = try await downloadWithProgress(request: request) { written, _ in
            onDelta(written)
        }
        guard let http = response as? HTTPURLResponse else {
            throw LocalAsrEngineError.invalidRegistryResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LocalAsrEngineError.downloadFailed(statusCode: http.statusCode)
        }

        if existing > 0, http.statusCode == 206 {
            if !fm.fileExists(atPath: partialURL.path) {
                fm.createFile(atPath: partialURL.path, contents: nil)
            }
            try appendContents(of: tempURL, onto: partialURL)
        } else {
            try? fm.removeItem(at: partialURL)
            try fm.moveItem(at: tempURL, to: partialURL)
        }
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: partialURL, to: dest)

        return max(0, (fileSize(at: dest) ?? 0) - existing)
    }

    private func downloadWithProgress(
        request: URLRequest,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> (URL, URLResponse) {
        let delegate = LocalAsrDownloadProgressDelegate(onProgress: onProgress)
        let session = URLSession(
            configuration: makeSessionConfiguration(),
            delegate: delegate,
            delegateQueue: nil
        )
        defer { session.finishTasksAndInvalidate() }
        return try await session.download(for: request)
    }

    private func localURL(for file: RemoteFile, repo: Repo) -> URL {
        cacheDirectory.appendingPathComponent(stripped(file.path, subPath: repo.subPath))
    }

    private func stripped(_ path: String, subPath: String?) -> String {
        guard let subPath, path.hasPrefix("\(subPath)/") else { return path }
        return String(path.dropFirst(subPath.count + 1))
    }

    private func fileSize(at url: URL) -> Int64? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else { return nil }
        return (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
    }

    private func appendContents(of source: URL, onto dest: URL) throws {
        let reader = try FileHandle(forReadingFrom: source)
        let writer = try FileHandle(forWritingTo: dest)
        defer {
            try? reader.close()
            try? writer.close()
        }
        try writer.seekToEnd()
        while true {
            let chunk = try reader.read(upToCount: 1_048_576) ?? Data()
            if chunk.isEmpty { break }
            try writer.write(contentsOf: chunk)
        }
    }

    private func makeSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 1_800
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        return configuration
    }

    private static func defaultsKey(for variant: Qwen3AsrVariant) -> String {
        "localAsr.\(variant.rawValue).totalBytes"
    }

    private static func rememberedTotalBytes(for variant: Qwen3AsrVariant) -> Int64 {
        Int64(UserDefaults.standard.integer(forKey: defaultsKey(for: variant)))
    }

    private static func rememberTotalBytes(_ value: Int64, for variant: Qwen3AsrVariant) {
        UserDefaults.standard.set(Int(value), forKey: defaultsKey(for: variant))
    }
}

private final class LocalAsrDownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
    private let onProgress: @Sendable (Int64, Int64) -> Void

    init(onProgress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        onProgress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {}
}
