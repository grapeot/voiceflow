import AppIntents

struct StartRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Recording"
    static let description = IntentDescription("Open VoiceFlow and start a new recording.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        StartRecordingIntentRequest.markPending()
        return .result()
    }
}

struct VoiceFlowShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartRecordingIntent(),
            phrases: [
                "Start recording in \(.applicationName)",
                "Record with \(.applicationName)"
            ],
            shortTitle: "Start Recording",
            systemImageName: "mic.fill"
        )
    }
}
