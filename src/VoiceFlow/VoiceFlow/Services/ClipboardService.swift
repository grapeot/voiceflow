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

    init(writeError: Error? = nil) {
        self.writeError = writeError
    }

    func write(_ text: String) throws {
        if let writeError {
            throw writeError
        }
        writtenText = text
    }
}
