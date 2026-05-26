import SwiftUI

struct RecordView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("record.transcript.placeholder")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .frame(minHeight: 120, alignment: .topLeading)
                            .accessibilityIdentifier("record.transcript")

                        Text("record.clipboard.hint")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("record.transcript.title")
                }

                Section {
                    HStack(spacing: 12) {
                        Button("record.start") {}
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("record.startButton")

                        Button("record.stop") {}
                            .buttonStyle(.bordered)
                            .disabled(appState.recordingStatus != .recording)
                            .accessibilityIdentifier("record.stopButton")
                    }

                    HStack(spacing: 12) {
                        Button("record.copy") {}
                            .disabled(!appState.canCopyTranscript)
                            .accessibilityIdentifier("record.copyButton")

                        Button("record.history") {}
                            .accessibilityIdentifier("record.historyButton")
                    }

                    Button("record.sendToOpenCode") {}
                        .disabled(!appState.canSendToOpenCode)
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
