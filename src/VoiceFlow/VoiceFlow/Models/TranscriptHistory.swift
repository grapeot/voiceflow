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
    private(set) var currentIndex: Int = 0
    private let limit: Int

    init(entries: [TranscriptEntry] = [], limit: Int = 5) {
        self.entries = Array(entries.prefix(limit))
        self.limit = limit
        self.currentIndex = 0
    }

    var hasNext: Bool {
        currentIndex > 0
    }

    var hasPrevious: Bool {
        !entries.isEmpty && currentIndex < entries.count - 1
    }

    mutating func add(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        entries.removeAll { $0.text == trimmed }
        entries.insert(TranscriptEntry(text: trimmed), at: 0)
        if entries.count > limit {
            entries = Array(entries.prefix(limit))
        }
        currentIndex = 0
    }

    mutating func navigatePrevious() -> String? {
        guard hasPrevious else { return nil }
        currentIndex += 1
        return entries[currentIndex].text
    }

    mutating func navigateNext() -> String? {
        guard hasNext else { return nil }
        currentIndex -= 1
        return entries[currentIndex].text
    }
}
