import Foundation

enum DeepLinkAction: Equatable {
    case startRecording
}

enum DeepLink {
    static let scheme = "voiceflow"
    static let recordHost = "record"

    static func parse(_ url: URL) -> DeepLinkAction? {
        guard url.scheme?.lowercased() == scheme else { return nil }

        let host = url.host?.lowercased()
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()

        if host == recordHost, path.isEmpty {
            return .startRecording
        }
        if host == nil || host?.isEmpty == true, path == recordHost {
            return .startRecording
        }
        return nil
    }

    static func diagnosticMetadata(for url: URL) -> [String: String] {
        [
            "scheme": url.scheme ?? "none",
            "host": url.host ?? "none",
            "pathLength": String(url.path.count),
            "hasQuery": url.query == nil ? "false" : "true"
        ]
    }
}
