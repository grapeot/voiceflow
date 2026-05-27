import SwiftUI

struct RecordView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.localizationBundle) private var localizationBundle
    @State private var showOpenCodeInfo = false

    var body: some View {
        ZStack {
            DesignTokens.Palette.bgPrimary.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer().frame(height: DesignTokens.Spacing.xxl)

                timerHeader

                Spacer().frame(height: DesignTokens.Spacing.l)

                WaveformView(mode: waveformMode, color: waveformColor)
                    .padding(.horizontal, DesignTokens.Spacing.xl)
                    .accessibilityIdentifier("record.waveform")

                Spacer().frame(height: DesignTokens.Spacing.xxl)

                transcriptArea

                Spacer(minLength: DesignTokens.Spacing.l)

                primaryAction

                Spacer().frame(height: DesignTokens.Spacing.m)

                secondaryControls

                Spacer().frame(height: DesignTokens.Spacing.l)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        #if os(visionOS)
        .frame(minWidth: 400, idealWidth: 600, maxWidth: 800,
               minHeight: 400, idealHeight: 1000, maxHeight: 1500)
        #endif
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

    // MARK: - Sections

    private var timerHeader: some View {
        VStack(spacing: DesignTokens.Spacing.s) {
            Text(appState.recordingTimerText)
                .font(DesignTokens.Typography.timer)
                .foregroundStyle(DesignTokens.Palette.textPrimary)
                .monospacedDigit()
                .accessibilityIdentifier("record.recordingTimer")

            StatusText(key: statusTextKey, role: statusTextRole)
                .padding(.horizontal, DesignTokens.Spacing.xl)
        }
    }

    private var transcriptArea: some View {
        ZStack {
            TextEditor(text: $appState.transcript)
                .font(DesignTokens.Typography.body)
                .foregroundStyle(DesignTokens.Palette.textPrimary)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .padding(.horizontal, DesignTokens.Spacing.xl - 5)
                .accessibilityIdentifier("record.transcript")
                .accessibilityValue(appState.transcript)

            if appState.transcript.isEmpty {
                // The hint is symmetric to the timer and waveform above it —
                // every element on the screen is centered. A lone left-aligned
                // placeholder reads as orphaned, especially in dark mode.
                Text(localized("record.transcript.placeholder"))
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(DesignTokens.Palette.textTertiary)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var primaryAction: some View {
        CapsuleButton(
            title: LocalizedStringKey(appState.canStopRecording ? "record.stop" : "record.start"),
            role: appState.canStopRecording ? .secondary : .primary,
            action: toggleRecording,
            icon: appState.canStopRecording ? "stop.fill" : "mic.fill",
            isEnabled: appState.canStartRecording || appState.canStopRecording
        )
        .accessibilityIdentifier(appState.canStopRecording ? "record.stopButton" : "record.startButton")
    }

    private var secondaryControls: some View {
        HStack(spacing: DesignTokens.Spacing.xl) {
            GhostIconButton(
                systemName: "chevron.left",
                action: appState.navigatePreviousTranscript,
                isEnabled: appState.canNavigatePreviousTranscript,
                accessibilityLabel: "record.history"
            )
            .accessibilityIdentifier("record.historyPreviousButton")

            Menu {
                Button(action: appState.copyTranscript) {
                    Label {
                        Text(localized("record.copy"))
                    } icon: {
                        Image(systemName: "doc.on.doc")
                    }
                }
                .disabled(!appState.canCopyTranscript)
                .accessibilityIdentifier("record.copyButton")

                Button(action: { Task { await appState.sendTranscriptToOpenCode() } }) {
                    Label {
                        Text(openCodeMenuLabel)
                    } icon: {
                        Image(systemName: openCodeMenuIcon)
                    }
                }
                .disabled(!appState.canSendToOpenCode || appState.openCodeSendStatus == .sending)
                .accessibilityIdentifier("record.sendOpenCodeButton")

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
                Image(systemName: "ellipsis")
                    .font(.system(size: DesignTokens.Sizing.ghostIcon, weight: .regular))
                    .frame(width: DesignTokens.Sizing.ghostButton,
                           height: DesignTokens.Sizing.ghostButton)
                    .foregroundStyle(DesignTokens.Palette.textSecondary)
            }
            .accessibilityIdentifier("record.moreButton")

            GhostIconButton(
                systemName: "chevron.right",
                action: appState.navigateNextTranscript,
                isEnabled: appState.canNavigateNextTranscript,
                accessibilityLabel: "record.history"
            )
            .accessibilityIdentifier("record.historyNextButton")
        }
    }

    // MARK: - State derivations

    private var waveformMode: WaveformView.Mode {
        switch appState.recordingStatus {
        case .recording:    return .active
        case .transcribing: return .generating
        default:            return .idle
        }
    }

    private var waveformColor: Color {
        switch appState.recordingStatus {
        case .recording:
            switch appState.streamConnectionPhase {
            case .connected, .generating: return DesignTokens.Palette.accent
            case .connecting, .recovering: return DesignTokens.Palette.textSecondary
            case .disconnected: return DesignTokens.Palette.textTertiary
            }
        case .transcribing:
            return DesignTokens.Palette.accent
        case .requestingPermission:
            return DesignTokens.Palette.textSecondary
        case .idle, .ready:
            return DesignTokens.Palette.textTertiary
        }
    }

    private var statusTextKey: LocalizedStringKey {
        if appState.openCodeSendStatus != .idle {
            return LocalizedStringKey(appState.openCodeSendStatus.localizedKey)
        }
        if let savedRecording = appState.lastSavedRecording {
            return LocalizedStringKey(String(
                format: localized("record.save.statusLine"),
                savedRecording.fileName
            ))
        }
        if let streamKey = appState.streamStatusCaptionKey {
            return LocalizedStringKey(streamKey)
        }
        if let clipboardKey = appState.lastClipboardStatusKey {
            return LocalizedStringKey(clipboardKey)
        }
        return LocalizedStringKey(appState.recordingStatus.localizedKey)
    }

    private var statusTextRole: StatusText.Role {
        switch appState.recordingStatus {
        case .recording:
            switch appState.streamConnectionPhase {
            case .connected, .generating: return .accent
            case .connecting, .recovering: return .neutral
            case .disconnected: return .muted
            }
        case .transcribing:
            return .accent
        case .idle, .ready, .requestingPermission:
            return .neutral
        }
    }

    private var openCodeMenuLabel: String {
        switch appState.openCodeSendStatus {
        case .sending: return localized("record.openCode.sending")
        case .success: return localized("record.openCode.sent")
        case .failed:  return localized("record.openCode.error.sendFailed")
        case .idle:    return localized("record.sendToOpenCode")
        }
    }

    private var openCodeMenuIcon: String {
        switch appState.openCodeSendStatus {
        case .sending: return "paperplane"
        case .success: return "checkmark.circle"
        case .failed:  return "exclamationmark.triangle"
        case .idle:    return "paperplane"
        }
    }

    // MARK: - Bindings

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

#Preview {
    NavigationStack {
        RecordView()
            .environmentObject(AppState())
    }
}
