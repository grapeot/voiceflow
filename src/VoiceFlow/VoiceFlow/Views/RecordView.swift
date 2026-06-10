import SwiftUI
import VoiceFlowKit

#if canImport(UIKit)
import UIKit
#endif

struct RecordView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.localizationBundle) private var localizationBundle
    @Environment(\.colorScheme) private var colorScheme
    @State private var showOpenCodeInfo = false

    var body: some View {
        ZStack {
            DesignTokens.Palette.bgPrimary.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer().frame(height: DesignTokens.Spacing.xxl)

                timerHeader

                Spacer().frame(height: DesignTokens.Spacing.l)

                WaveformView(
                    mode: waveformMode,
                    color: waveformColor,
                    level: appState.audioLevel
                )
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
            // Timer uses the regular system face (56pt thin) — the Pixelate
            // look is dialed back to a hint, so the big timer stays neutral.
            // monospacedDigit keeps the digits from jittering as they tick.
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
        // The editor is its own view bound to `$appState.transcript`, so a
        // streamed transcript update invalidates only this subview — not the
        // whole RecordView body (which also reads audioLevel, timer text,
        // recordingStatus, button states…). That body-wide invalidation was
        // what made the *whole UI* flash on every partial.
        TranscriptEditor(
            text: $appState.transcript,
            placeholder: localized("record.transcript.placeholder")
        )
        .frame(maxHeight: .infinity)
    }

    private var primaryAction: some View {
        CapsuleButton(
            title: LocalizedStringKey(appState.canStopRecording ? "record.stop" : "record.start"),
            role: appState.canStopRecording ? .secondary : .primary,
            action: toggleRecording,
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
                .disabled(!appState.canResendRecording)
                .accessibilityIdentifier("record.resendRecordingButton")
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: DesignTokens.Sizing.ghostIcon, weight: .regular))
                    .frame(width: DesignTokens.Sizing.ghostButton,
                           height: DesignTokens.Sizing.ghostButton)
                    .foregroundStyle(DesignTokens.Palette.textSecondary)
                    .contentShape(.hoverEffect, Circle())
                    .hoverEffect(.lift)
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
            case .connecting, .recovering: return DesignTokens.Palette.textSecondary.color(for: colorScheme)
            case .disconnected: return DesignTokens.Palette.textTertiary.color(for: colorScheme)
            }
        case .transcribing:
            return DesignTokens.Palette.accent
        case .requestingPermission:
            return DesignTokens.Palette.textSecondary.color(for: colorScheme)
        case .idle, .ready:
            return DesignTokens.Palette.textTertiary.color(for: colorScheme)
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

/// The transcript text editor as its own view. Bound to the transcript string,
/// so a streamed update re-evaluates only this view rather than the entire
/// RecordView body — which is what stops the whole screen flashing per partial.
private struct TranscriptEditor: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        ZStack {
            AutoScrollingTextEditor(text: $text)
                .padding(.horizontal, DesignTokens.Spacing.xl - 5)
                .accessibilityIdentifier("record.transcript")

            if text.isEmpty {
                // The hint is symmetric to the timer and waveform above it —
                // every element on the screen is centered. A lone left-aligned
                // placeholder reads as orphaned, especially in dark mode.
                Text(placeholder)
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(DesignTokens.Palette.textTertiary)
                    .allowsHitTesting(false)
            }
        }
    }
}

#if canImport(UIKit)
private struct AutoScrollingTextEditor: UIViewRepresentable {
    @Binding var text: String

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.font = .systemFont(ofSize: 17, weight: .regular)
        textView.textColor = .label
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.isScrollEnabled = true
        textView.alwaysBounceVertical = true
        textView.accessibilityIdentifier = "record.transcript"
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        guard textView.text != text else { return }
        textView.text = text
        scrollToBottom(textView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    private func scrollToBottom(_ textView: UITextView) {
        DispatchQueue.main.async {
            guard !textView.text.isEmpty else { return }
            let length = (textView.text as NSString).length
            let endRange = NSRange(location: max(length - 1, 0), length: 1)
            textView.scrollRangeToVisible(endRange)
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        private var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textViewDidChange(_ textView: UITextView) {
            text.wrappedValue = textView.text
        }
    }
}
#else
private struct AutoScrollingTextEditor: View {
    @Binding var text: String

    var body: some View {
        TextEditor(text: $text)
            .font(DesignTokens.Typography.body)
            .foregroundStyle(DesignTokens.Palette.textPrimary)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
    }
}
#endif

#Preview {
    NavigationStack {
        RecordView()
            .environmentObject(AppState())
    }
}
