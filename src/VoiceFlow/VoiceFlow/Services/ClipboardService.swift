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
    private(set) var writtenText: String?

    func write(_ text: String) throws {
        writtenText = text
    }
}
