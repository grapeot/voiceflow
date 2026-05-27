import SwiftUI

struct RecordView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.localizationBundle) private var localizationBundle
    @State private var showOpenCodeInfo = false

    var body: some View {
        VStack(spacing: 8) {
            statusHeader

            RecordingTimerView(timeString: appState.recordingTimerText)

            recordingControls

            transcriptPanel
                .frame(maxHeight: .infinity)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        #if os(visionOS)
        .frame(minWidth: 400, idealWidth: 600, maxWidth: 800,
               minHeight: 400, idealHeight: 1000, maxHeight: 1500)
        #endif
        .toolbar(.hidden, for: .navigationBar)
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
        .alert(
            Text(localized("record.sendToOpenCode")),
            isPresented: $showOpenCodeInfo
        ) {
            Button(localized("record.error.alert.ok"), role: .cancel) {}
                .accessibilityIdentifier("record.openCode.info.okButton")
        } message: {
            Text(localized("record.openCode.optional"))
        }
        .alert(
            Text(localized("record.save.confirmation.title")),
            isPresented: savedRecordingAlertPresented
        ) {
            Button(localized("record.error.alert.ok"), role: .cancel) {
                appState.acknowledgeSavedRecordingAlert()
            }
            .accessibilityIdentifier("record.save.confirmation.okButton")
        } message: {
            if let savedRecording = appState.lastSavedRecording {
                Text(
                    String(
                        format: localized("record.save.confirmation.message"),
                        savedRecording.fileName
                    )
                )
            }
        }
    }

    private var savedRecordingAlertPresented: Binding<Bool> {
        Binding(
            get: { appState.shouldPresentSavedRecordingAlert },
            set: { isPresented in
                if !isPresented {
                    appState.acknowledgeSavedRecordingAlert()
                }
            }
        )
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
            RecordingStatusHeaderView(
                recordingStatus: appState.recordingStatus,
                streamConnectionPhase: appState.streamConnectionPhase
            )

            statusLine
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var statusLine: some View {
        if appState.openCodeSendStatus != .idle {
            Text(localized(appState.openCodeSendStatus.localizedKey))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        } else if let savedRecording = appState.lastSavedRecording {
            Text(
                String(
                    format: localized("record.save.statusLine"),
                    savedRecording.fileName
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(3)
            .multilineTextAlignment(.center)
            .accessibilityIdentifier("record.save.statusLine")
        } else if let lastClipboardStatusKey = appState.lastClipboardStatusKey {
            Text(localized(lastClipboardStatusKey))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
    }

    private var recordingControls: some View {
        HStack(spacing: 20) {
            Button(action: appState.navigatePreviousTranscript) {
                Image(systemName: "chevron.left")
                    .font(.title2)
                    .foregroundStyle(appState.canNavigatePreviousTranscript ? .blue : .gray)
            }
            .disabled(!appState.canNavigatePreviousTranscript)
            .accessibilityIdentifier("record.historyPreviousButton")

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
                fixedWidth: 120
            ))
            .disabled(!appState.canStartRecording && !appState.canStopRecording)
            .accessibilityIdentifier(appState.canStopRecording ? "record.stopButton" : "record.startButton")

            Menu {
                Button(action: appState.saveCurrentRecording) {
                    Label {
                        Text(localized("record.saveRecording"))
                    } icon: {
                        Image(systemName: "square.and.arrow.down")
                    }
                }
                .disabled(!appState.canSaveRecording)
                .accessibilityIdentifier("record.saveRecordingButton")

                Button(action: { Task { await appState.resendLastRecording() } }) {
                    Label {
                        Text(localized("record.resendRecording"))
                    } icon: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(!appState.canResendRecording || appState.recordingStatus == .transcribing)
                .accessibilityIdentifier("record.resendRecordingButton")
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title2)
                    .foregroundStyle(.blue)
            }
            .accessibilityIdentifier("record.moreButton")

            Button(action: appState.navigateNextTranscript) {
                Image(systemName: "chevron.right")
                    .font(.title2)
                    .foregroundStyle(appState.canNavigateNextTranscript ? .blue : .gray)
            }
            .disabled(!appState.canNavigateNextTranscript)
            .accessibilityIdentifier("record.historyNextButton")
        }
        .padding(.horizontal)
    }

    private var transcriptPanel: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $appState.transcript)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                    .padding(.bottom, 8)
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
            .overlay(alignment: .bottomTrailing) {
                Text(transcriptCharacterCountLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .accessibilityIdentifier("record.transcriptCharacterCount")
                    .allowsHitTesting(false)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

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

                HStack(spacing: 8) {
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
                    .disabled(!appState.canSendToOpenCode || appState.openCodeSendStatus == .sending)
                    .accessibilityIdentifier("record.sendOpenCodeButton")
                    .accessibilityLabel(Text(localized("record.sendToOpenCode")))

                    Button {
                        showOpenCodeInfo = true
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("record.openCode.infoButton")
                    .accessibilityLabel(Text(localized("record.openCode.info.accessibility")))
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.top, 12)
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
        }
        .clipped()
    }

    private var transcriptCharacterCountLabel: String {
        String(
            format: localized("record.transcript.characterCount"),
            appState.transcript.count
        )
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
