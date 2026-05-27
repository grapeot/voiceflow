import SwiftUI

struct RecordView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(appState.transcript.isEmpty ? String(localized: "record.transcript.placeholder") : appState.transcript)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .frame(minHeight: 120, alignment: .topLeading)
                            .accessibilityIdentifier("record.transcript")

                        Text(appState.recordingStatus.localizedText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("record.status")

                        Text("record.clipboard.hint")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        if let lastClipboardStatus = appState.lastClipboardStatus {
                            Text(lastClipboardStatus)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("record.clipboardStatus")
                        }

                        if appState.openCodeSendStatus != .idle {
                            Text(appState.openCodeSendStatus.localizedText)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("record.openCodeSendStatus")
                        }
                    }
                } header: {
                    Text("record.transcript.title")
                }

                Section {
                    HStack(spacing: 12) {
                        Button("record.start") {
                            Task { await appState.startRecording() }
                        }
                            .buttonStyle(.borderedProminent)
                            .disabled(!appState.canStartRecording)
                            .accessibilityIdentifier("record.startButton")

                        Button("record.stop") {
                            Task { await appState.stopRecording() }
                        }
                            .buttonStyle(.bordered)
                            .disabled(!appState.canStopRecording)
                            .accessibilityIdentifier("record.stopButton")
                    }

                    HStack(spacing: 12) {
                        Button("record.copy") {
                            appState.copyTranscript()
                        }
                            .disabled(!appState.canCopyTranscript)
                            .accessibilityIdentifier("record.copyButton")

                        Button("record.history") {
                            appState.restorePreviousTranscript()
                        }
                            .disabled(!appState.canRestorePreviousTranscript)
                            .accessibilityIdentifier("record.historyButton")
                    }

                    Button("record.sendToOpenCode") {
                        Task { await appState.sendTranscriptToOpenCode() }
                    }
                        .disabled(!appState.canSendToOpenCode || appState.openCodeSendStatus == .sending)
                        .accessibilityIdentifier("record.sendOpenCodeButton")
                } header: {
                    Text("record.controls.title")
                } footer: {
                    Text("record.openCode.optional")
                }
            }
            .navigationTitle(Text("tab.record"))
        }
    }
}

#Preview {
    RecordView()
        .environmentObject(AppState())
}
