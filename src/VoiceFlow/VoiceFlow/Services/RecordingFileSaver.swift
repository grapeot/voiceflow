import Foundation

enum RecordingFileSaver {
    static func makeDestinationURL(
        in documentsDirectory: URL,
        date: Date = Date(),
        fileExtension: String = "wav"
    ) -> URL {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let normalizedExtension = fileExtension.isEmpty ? "wav" : fileExtension.lowercased()
        let fileName = "recording_\(dateFormatter.string(from: date)).\(normalizedExtension)"
        return documentsDirectory.appendingPathComponent(fileName)
    }

    static func saveRecording(from sourceURL: URL, to destinationURL: URL, fileManager: FileManager = .default) throws {
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
    }
}
