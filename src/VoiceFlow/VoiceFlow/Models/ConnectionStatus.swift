import Foundation

enum ConnectionStatus: Equatable {
    case untested
    case testing
    case success
    case failed(String)

    var localizedKey: String {
        switch self {
        case .untested:
            "settings.connection.untested"
        case .testing:
            "settings.connection.testing"
        case .success:
            "settings.connection.success"
        case .failed(let key):
            key
        }
    }

    var openCodeLocalizedKey: String {
        switch self {
        case .untested:
            "settings.openCode.connection.untested"
        case .testing:
            "settings.openCode.connection.testing"
        case .success:
            "settings.openCode.connection.success"
        case .failed(let key):
            key
        }
    }
}
