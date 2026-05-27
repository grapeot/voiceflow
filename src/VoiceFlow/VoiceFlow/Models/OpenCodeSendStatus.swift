import Foundation

enum OpenCodeSendStatus: Equatable {
    case idle
    case sending
    case success
    case failed(String)

    var localizedText: String {
        switch self {
        case .idle:
            String(localized: "record.openCode.idle")
        case .sending:
            String(localized: "record.openCode.sending")
        case .success:
            String(localized: "record.openCode.sent")
        case .failed(let message):
            message
        }
    }
}
