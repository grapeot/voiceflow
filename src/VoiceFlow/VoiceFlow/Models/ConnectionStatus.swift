import Foundation

enum ConnectionStatus: Equatable {
    case untested
    case testing
    case success
    case failed(String)

    var localizedText: String {
        switch self {
        case .untested:
            String(localized: "settings.connection.untested")
        case .testing:
            String(localized: "settings.connection.testing")
        case .success:
            String(localized: "settings.connection.success")
        case .failed(let message):
            message
        }
    }
}
