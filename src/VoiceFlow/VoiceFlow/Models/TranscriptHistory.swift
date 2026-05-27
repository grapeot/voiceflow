import Foundation

struct TranscriptEntry: Codable, Equatable, Identifiable {
    let id: UUID
    let text: String
    let createdAt: Date

    init(id: UUID = UUID(), text: String, createdAt: Date = Date()) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
    }
}

struct TranscriptHistory: Equatable {
    private(set) var entries: [TranscriptEntry]
    private let limit: Int

    init(entries: [TranscriptEntry] = [], limit: Int = 5) {
        self.entries = Array(entries.prefix(limit))
        self.limit = limit
    }

    var canRestorePrevious: Bool {
        !entries.isEmpty
    }

    mutating func add(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        entries.removeAll { $0.text == trimmed }
        entries.insert(TranscriptEntry(text: trimmed), at: 0)
        if entries.count > limit {
            entries = Array(entries.prefix(limit))
        }
    }

    mutating func restorePrevious(currentText: String) -> String? {
        guard !entries.isEmpty else { return nil }
        let currentIndex = entries.firstIndex { $0.text == currentText }
        let targetIndex: Int
        if let currentIndex, currentIndex + 1 < entries.count {
            targetIndex = currentIndex + 1
        } else {
            targetIndex = 0
        }
        return entries[targetIndex].text
    }
}
