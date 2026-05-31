import Foundation
import UIKit

protocol ClipboardWriting {
    func write(_ text: String) throws
}

struct SystemClipboardWriter: ClipboardWriting {
    func write(_ text: String) throws {
        UIPasteboard.general.string = text
    }
}

final class MockClipboardWriter: ClipboardWriting {
    var writeError: Error?
    private(set) var writtenText: String?
    private(set) var writeCount = 0

    init(writeError: Error? = nil) {
        self.writeError = writeError
    }

    func write(_ text: String) throws {
        if let writeError {
            throw writeError
        }
        writeCount += 1
        writtenText = text
    }
}
