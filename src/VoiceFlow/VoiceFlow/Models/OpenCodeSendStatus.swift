import Foundation

enum OpenCodeSendStatus: Equatable {
    case idle
    case sending
    case success
    case failed(String)

    var localizedKey: String {
        switch self {
        case .idle:
            "record.openCode.idle"
        case .sending:
            "record.openCode.sending"
        case .success:
            "record.openCode.sent"
        case .failed(let key):
            key
        }
    }
}
