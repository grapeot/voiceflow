import Foundation

enum StartRecordingIntentRequest {
    private static let pendingKey = "startRecordingIntentPending"

    static func markPending() {
        UserDefaults.standard.set(true, forKey: pendingKey)
    }

    static func consumePending() -> Bool {
        guard UserDefaults.standard.bool(forKey: pendingKey) else { return false }
        UserDefaults.standard.removeObject(forKey: pendingKey)
        return true
    }

    #if DEBUG
    static func clearPendingForTests() {
        UserDefaults.standard.removeObject(forKey: pendingKey)
    }
    #endif
}
