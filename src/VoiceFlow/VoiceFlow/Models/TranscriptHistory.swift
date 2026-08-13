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

    /// Transactional insertion for a text transformation. The result becomes
    /// the newest entry (index 0); the source text follows it (index 1) so
    /// the user can navigate back to the original. If the source is already
    /// the current head, it is not inserted twice. Unlike `add`, this does
    /// NOT globally remove older matching entries — equal text can be a
    /// legitimate later recording or operation. The five-entry limit is
    /// applied after both insertions.
    ///
    /// Returns the text the editor should show next (the result), or nil if
    /// either input was empty after trimming.
    @discardableResult
    mutating func addTransform(result: String, source: String) -> String? {
        let trimmedResult = result.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedResult.isEmpty else { return nil }

        entries.insert(TranscriptEntry(text: trimmedResult), at: 0)
        // Avoid duplicating the source if it is already the (now index-1)
        // head, or empty.
        if !trimmedSource.isEmpty,
           !(entries.count >= 2 && entries[1].text == trimmedSource) {
            entries.insert(TranscriptEntry(text: trimmedSource), at: 1)
        }
        if entries.count > limit {
            entries = Array(entries.prefix(limit))
        }
        currentIndex = 0
        return trimmedResult
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
