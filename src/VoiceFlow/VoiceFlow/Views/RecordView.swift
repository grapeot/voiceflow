import SwiftUI

struct RecordView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.localizationBundle) private var localizationBundle

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 8) {
                statusHeader
                    .frame(height: geometry.size.height * 0.10)

                recordingControls
                    .frame(height: geometry.size.height * 0.12)

                transcriptPanel
                    .frame(height: geometry.size.height * 0.68)
            }
            .padding()
            .contentShape(Rectangle())
        }
        #if os(visionOS)
        .frame(minWidth: 400, idealWidth: 600, maxWidth: 800,
               minHeight: 400, idealHeight: 1000, maxHeight: 1500)
        #endif
        .navigationTitle(Text(localized("tab.record")))
        .alert(
            Text(localized("record.error.alert.title")),
            isPresented: recordErrorAlertPresented
        ) {
            Button(localized("record.error.alert.ok"), role: .cancel) {
                appState.dismissRecordError()
            }
            .accessibilityIdentifier("record.error.alert.okButton")
        } message: {
            if let key = appState.recordErrorAlertKey {
                Text(localized(key))
            }
        }
    }

    private var recordErrorAlertPresented: Binding<Bool> {
        Binding(
            get: { appState.recordErrorAlertKey != nil },
            set: { isPresented in
                if !isPresented {
                    appState.dismissRecordError()
                }
            }
        )
    }

    private var statusHeader: some View {
        VStack(spacing: 4) {
            recordingStatusText
                .font(.largeTitle)
                .fontWeight(.bold)
                .minimumScaleFactor(0.7)
                .accessibilityIdentifier("record.status")

            statusLine
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private var statusLine: Text {
        if appState.openCodeSendStatus != .idle {
            Text(localized(appState.openCodeSendStatus.localizedKey))
        } else if let lastClipboardStatusKey = appState.lastClipboardStatusKey {
            Text(localized(lastClipboardStatusKey))
        } else {
            Text(localized("record.clipboard.hint"))
        }
    }

    private var recordingStatusText: Text {
        Text(localized(appState.recordingStatus.localizedKey))
    }

    private var recordingControls: some View {
        HStack(spacing: 20) {
            Button(action: appState.restorePreviousTranscript) {
                Image(systemName: "chevron.left")
                    .font(.title2)
                    .foregroundStyle(appState.canRestorePreviousTranscript ? .blue : .gray)
            }
            .disabled(!appState.canRestorePreviousTranscript)
            .accessibilityIdentifier("record.historyButton")

            Button(action: toggleRecording) {
                HStack {
                    Image(systemName: appState.canStopRecording ? "stop.fill" : "play.fill")
                    Text(localized(appState.canStopRecording ? "record.stop" : "record.start"))
                }
                .font(.title2)
            }
            .buttonStyle(ColoredButtonStyle(
                backgroundColor: appState.canStopRecording ? .red : .blue,
                fixedHeight: 60,
                fixedWidth: 180
            ))
            .disabled(!appState.canStartRecording && !appState.canStopRecording)
            .accessibilityIdentifier(appState.canStopRecording ? "record.stopButton" : "record.startButton")

            Menu {
                Button(action: appState.copyTranscript) {
                    Label {
                        Text(localized("record.copy"))
                    } icon: {
                        Image(systemName: "doc.on.doc")
                    }
                }
                .disabled(!appState.canCopyTranscript)

                Button(action: { Task { await appState.sendTranscriptToOpenCode() } }) {
                    Label {
                        Text(localized("record.sendToOpenCode"))
                    } icon: {
                        Image(systemName: "paperplane.fill")
                    }
                }
                .disabled(!appState.canSendToOpenCode || appState.openCodeSendStatus == .sending)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title2)
                    .foregroundStyle(.blue)
            }
            .accessibilityIdentifier("record.moreButton")
        }
        .padding()
    }

    private var transcriptPanel: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $appState.transcript)
                    .padding()
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                    )
                    .accessibilityIdentifier("record.transcript")
                    .accessibilityValue(appState.transcript)

                if appState.transcript.isEmpty {
                    Text(localized("record.transcript.placeholder"))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 28)
                        .allowsHitTesting(false)
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 12) {
                Button(action: appState.copyTranscript) {
                    HStack {
                        Image(systemName: "doc.on.doc")
                        Text(localized("record.copy"))
                    }
                }
                .buttonStyle(ColoredButtonStyle(backgroundColor: .blue, fixedHeight: 60, fixedWidth: 150))
                .frame(maxWidth: .infinity)
                .disabled(!appState.canCopyTranscript)
                .accessibilityIdentifier("record.copyButton")

                Button(action: { Task { await appState.sendTranscriptToOpenCode() } }) {
                    HStack {
                        switch appState.openCodeSendStatus {
                        case .sending:
                            ProgressView()
                                .scaleEffect(0.8)
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            Text(localized("record.openCode.sending"))
                        case .success:
                            Image(systemName: "checkmark.circle.fill")
                            Text(localized("record.openCode.sent"))
                        case .failed:
                            Image(systemName: "exclamationmark.triangle.fill")
                            Text(localized("record.openCode.error.sendFailed"))
                        case .idle:
                            Text("🧠")
                            Text(localized("record.sendToOpenCode"))
                        }
                    }
                }
                .buttonStyle(ColoredButtonStyle(
                    backgroundColor: appState.openCodeSendStatus == .success ? .green : appState.openCodeSendStatus.isFailed ? .red : .purple,
                    fixedHeight: 60,
                    fixedWidth: 170
                ))
                .frame(maxWidth: .infinity)
                .disabled(!appState.canSendToOpenCode || appState.openCodeSendStatus == .sending)
                .accessibilityIdentifier("record.sendOpenCodeButton")
                .accessibilityLabel(Text(localized("record.sendToOpenCode")))
            }
            .padding(.top, 16)
            .padding(.horizontal, 20)
            .padding(.bottom, 20)

            Text(localized("record.openCode.optional"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
        }
    }

    private func toggleRecording() {
        if appState.canStopRecording {
            Task { await appState.stopRecording() }
        } else {
            Task { await appState.startRecording() }
        }
    }

    private func localized(_ key: String) -> String {
        String(localized: String.LocalizationValue(key), bundle: localizationBundle)
    }
}

private extension OpenCodeSendStatus {
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

#Preview {
    NavigationStack {
        RecordView()
            .environmentObject(AppState())
    }
}
