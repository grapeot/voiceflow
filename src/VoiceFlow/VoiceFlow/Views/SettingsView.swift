import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.localizationBundle) private var localizationBundle
    @State private var tokenInput = ""
    @State private var openCodePasswordInput = ""

    var body: some View {
        NavigationStack {
            ZStack {
                DesignTokens.Palette.bgPrimary.ignoresSafeArea()

                Form {
                    aiBuilderSection
                    transcriptionSection
                    openCodeSection
                    languageSection
                    uiTestSection
                }
                .scrollContentBackground(.hidden)
                #if !os(visionOS)
                .scrollDismissesKeyboard(.interactively)
                #endif
                .tint(DesignTokens.Palette.accent)
            }
            .navigationTitle(Text(localized("tab.settings")))
            .dismissKeyboardOnTapOutsideTextInputs()
            .toolbarColorScheme(nil, for: .navigationBar)
        }
    }

    private var aiBuilderSection: some View {
        Section {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.s) {
                Text(localized("settings.apiToken.placeholder"))
                    .font(DesignTokens.Typography.bodyBold)
                    .foregroundStyle(DesignTokens.Palette.textPrimary)

                if appState.hasSavedAIBuilderToken {
                    Text(appState.tokenDisplayValue)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(DesignTokens.Palette.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .inputCardSurface()
                        .accessibilityIdentifier("settings.apiTokenMaskedValue")
                } else {
                    SecureField(localized("settings.apiToken.placeholder"), text: $tokenInput)
                        .textContentType(.password)
                        .textFieldStyle(.plain)
                        .font(DesignTokens.Typography.body)
                        .foregroundStyle(DesignTokens.Palette.textPrimary)
                        .inputCardSurface()
                        .accessibilityIdentifier("settings.apiTokenField")
                }
            }

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                Text(localized("settings.endpoint.title"))
                    .font(DesignTokens.Typography.captionSub)
                    .foregroundStyle(DesignTokens.Palette.textSecondary)
                    .accessibilityIdentifier("settings.endpointTitle")

                Text(appState.aiBuilderEndpoint)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Palette.textTertiary)
                    .accessibilityIdentifier("settings.endpointValue")
            }

            HStack {
                Text(localized("settings.apiToken.status"))
                    .font(DesignTokens.Typography.captionSub)
                    .foregroundStyle(DesignTokens.Palette.textSecondary)
                Spacer()
                Text(localized(appState.hasSavedAIBuilderToken ? "settings.apiToken.saved" : "settings.apiToken.notSaved"))
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Palette.textSecondary)
                    .accessibilityIdentifier("settings.apiTokenStatus")
            }

            HStack(spacing: DesignTokens.Spacing.m) {
                Button(localized("settings.apiToken.save")) {
                    appState.saveAIBuilderToken(tokenInput)
                    tokenInput = ""
                }
                .buttonStyle(.borderless)
                .foregroundStyle(DesignTokens.Palette.accent)
                .disabled(appState.hasSavedAIBuilderToken || tokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("settings.saveTokenButton")

                Spacer()

                Button(localized("settings.apiToken.clear"), role: .destructive) {
                    appState.clearAIBuilderToken()
                    tokenInput = ""
                }
                .buttonStyle(.borderless)
                .foregroundStyle(DesignTokens.Palette.textSecondary)
                .disabled(!appState.hasSavedAIBuilderToken)
                .accessibilityIdentifier("settings.clearTokenButton")
            }

            Button(localized("settings.testConnection")) {
                Task { await appState.testAIBuilderConnection() }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(DesignTokens.Palette.accent)
            .disabled(!appState.hasSavedAIBuilderToken || appState.connectionStatus == .testing)
            .accessibilityIdentifier("settings.testConnectionButton")

            connectionStatusView(
                status: appState.connectionStatus,
                identifier: "settings.connectionStatus",
                detailIdentifier: "settings.connectionStatusDetail"
            )

            Text(localized("settings.apiToken.securityHint"))
                .font(DesignTokens.Typography.captionSub)
                .foregroundStyle(DesignTokens.Palette.textTertiary)
        } header: {
            Text(localized("settings.aiBuilder.title"))
                .font(DesignTokens.Typography.bodyBold)
                .foregroundStyle(DesignTokens.Palette.textPrimary)
                .textCase(nil)
        }
        .listRowBackground(DesignTokens.Palette.bgSecondary)
    }

    private var openCodeSection: some View {
        Section {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                Text(localized("settings.openCode.serverURL"))
                    .font(DesignTokens.Typography.captionSub)
                    .foregroundStyle(DesignTokens.Palette.textSecondary)
                TextField(localized("settings.openCode.serverURL"), text: $appState.openCodeServerURL)
                    .textFieldStyle(.plain)
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(DesignTokens.Palette.textPrimary)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .inputCardSurface()
                    .accessibilityIdentifier("settings.openCodeServerURLField")
            }

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                Text(localized("settings.openCode.username"))
                    .font(DesignTokens.Typography.captionSub)
                    .foregroundStyle(DesignTokens.Palette.textSecondary)
                TextField(localized("settings.openCode.username"), text: $appState.openCodeUsername)
                    .textFieldStyle(.plain)
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(DesignTokens.Palette.textPrimary)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .inputCardSurface()
                    .accessibilityIdentifier("settings.openCodeUsernameField")
            }

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                Text(localized("settings.openCode.password"))
                    .font(DesignTokens.Typography.captionSub)
                    .foregroundStyle(DesignTokens.Palette.textSecondary)

                if appState.hasSavedOpenCodePassword {
                    Text(appState.openCodePasswordDisplayValue)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(DesignTokens.Palette.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .inputCardSurface()
                        .accessibilityIdentifier("settings.openCodePasswordMaskedValue")
                } else {
                    SecureField(localized("settings.openCode.password"), text: $openCodePasswordInput)
                        .textContentType(.password)
                        .textFieldStyle(.plain)
                        .font(DesignTokens.Typography.body)
                        .foregroundStyle(DesignTokens.Palette.textPrimary)
                        .inputCardSurface()
                        .accessibilityIdentifier("settings.openCodePasswordField")
                }
            }

            HStack {
                Text(localized("settings.openCode.status"))
                    .font(DesignTokens.Typography.captionSub)
                    .foregroundStyle(DesignTokens.Palette.textSecondary)
                Spacer()
                Text(localized(appState.isOpenCodeConfigured ? "settings.openCode.configured" : "settings.openCode.notConfigured"))
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Palette.textSecondary)
                    .accessibilityIdentifier("settings.openCodeStatus")
            }

            HStack(spacing: DesignTokens.Spacing.m) {
                Button(localized("settings.openCode.save")) {
                    appState.saveOpenCodePassword(openCodePasswordInput)
                    openCodePasswordInput = ""
                }
                .buttonStyle(.borderless)
                .foregroundStyle(DesignTokens.Palette.accent)
                .disabled(appState.hasSavedOpenCodePassword
                          || openCodePasswordInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || appState.openCodeServerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || appState.openCodeUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("settings.saveOpenCodeButton")

                Spacer()

                Button(localized("settings.openCode.clear"), role: .destructive) {
                    appState.clearOpenCodePassword()
                    openCodePasswordInput = ""
                }
                .buttonStyle(.borderless)
                .foregroundStyle(DesignTokens.Palette.textSecondary)
                .disabled(!appState.hasSavedOpenCodePassword)
                .accessibilityIdentifier("settings.clearOpenCodeButton")
            }

            Button(localized("settings.openCode.testConnection")) {
                Task { await appState.testOpenCodeConnection() }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(DesignTokens.Palette.accent)
            .disabled(!appState.isOpenCodeConfigured || appState.openCodeConnectionStatus == .testing)
            .accessibilityIdentifier("settings.testOpenCodeConnectionButton")

            connectionStatusView(
                status: appState.openCodeConnectionStatus,
                localizedKey: { $0.openCodeLocalizedKey },
                identifier: "settings.openCodeConnectionStatus",
                detailIdentifier: "settings.openCodeConnectionStatusDetail"
            )

            Text(localized("settings.openCode.optionalHint"))
                .font(DesignTokens.Typography.captionSub)
                .foregroundStyle(DesignTokens.Palette.textTertiary)
        } header: {
            Text(localized("settings.openCode.title"))
                .font(DesignTokens.Typography.bodyBold)
                .foregroundStyle(DesignTokens.Palette.textPrimary)
                .textCase(nil)
        }
        .listRowBackground(DesignTokens.Palette.bgSecondary)
    }

    @ViewBuilder
    private var uiTestSection: some View {
        if ProcessInfo.processInfo.arguments.contains("-uiTestMode") {
            Section {
                Button("Reset UI Test State") {
                    Task { @MainActor in
                        await appState.resetForUITest()
                    }
                }
                .foregroundStyle(DesignTokens.Palette.accent)
                .accessibilityIdentifier("uitest.resetState")
            }
            .listRowBackground(DesignTokens.Palette.bgSecondary)
        }
    }

    private var transcriptionSection: some View {
        Section {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.m) {
                Text(localized("settings.transcription.description"))
                    .font(DesignTokens.Typography.captionSub)
                    .foregroundStyle(DesignTokens.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                inputField(
                    label: "settings.transcription.prompt",
                    placeholder: "settings.transcription.prompt.placeholder",
                    text: $appState.transcriptionPrompt,
                    accessibilityIdentifier: "settings.transcriptionPromptField",
                    multiline: true,
                    capitalize: true
                )

                inputField(
                    label: "settings.transcription.terms",
                    placeholder: "settings.transcription.terms.placeholder",
                    text: $appState.transcriptionTerms,
                    accessibilityIdentifier: "settings.transcriptionTermsField",
                    multiline: true,
                    capitalize: false
                )
            }
            .padding(.vertical, DesignTokens.Spacing.xs)
        } header: {
            Text(localized("settings.transcription.title"))
                .font(DesignTokens.Typography.bodyBold)
                .foregroundStyle(DesignTokens.Palette.textPrimary)
                .textCase(nil)
        }
        .listRowBackground(DesignTokens.Palette.bgSecondary)
    }

    /// Visual cue for "this is an input": a filled rounded surface in
    /// `bg.primary` floating on the section's `bg.secondary`. Same
    /// shape works for single-line and multi-line — multiline just
    /// gets `axis: .vertical` and grows.
    @ViewBuilder
    private func inputField(
        label labelKey: String,
        placeholder placeholderKey: String,
        text: Binding<String>,
        accessibilityIdentifier identifier: String,
        multiline: Bool = false,
        capitalize: Bool = true
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text(localized(labelKey))
                .font(DesignTokens.Typography.captionSub)
                .foregroundStyle(DesignTokens.Palette.textSecondary)

            let field: AnyView = {
                if multiline {
                    return AnyView(
                        TextField(localized(placeholderKey), text: text, axis: .vertical)
                            .lineLimit(2...4)
                    )
                } else {
                    return AnyView(TextField(localized(placeholderKey), text: text))
                }
            }()

            field
                .textFieldStyle(.plain)
                .font(DesignTokens.Typography.body)
                .foregroundStyle(DesignTokens.Palette.textPrimary)
                .textInputAutocapitalization(capitalize ? .sentences : .never)
                .autocorrectionDisabled(!capitalize)
                .inputCardSurface()
                .accessibilityIdentifier(identifier)
        }
    }

    private var languageSection: some View {
        Section {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.s) {
                Text(localized("settings.language.description"))
                    .font(DesignTokens.Typography.captionSub)
                    .foregroundStyle(DesignTokens.Palette.textTertiary)

                Picker(localized("settings.language.title"), selection: $appState.appLanguage) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(localized(language.localizedTitleKey))
                            .tag(language)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("settings.languagePicker")
            }
        } header: {
            Text(localized("settings.language.title"))
                .font(DesignTokens.Typography.bodyBold)
                .foregroundStyle(DesignTokens.Palette.textPrimary)
                .textCase(nil)
        }
        .listRowBackground(DesignTokens.Palette.bgSecondary)
    }

    @ViewBuilder
    private func connectionStatusView(
        status: ConnectionStatus,
        localizedKey: (ConnectionStatus) -> String = { $0.localizedKey },
        identifier: String,
        detailIdentifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text(localized(localizedKey(status)))
                .font(DesignTokens.Typography.captionSub)
                .foregroundStyle(
                    status.detail == nil
                    ? DesignTokens.Palette.textSecondary
                    : DesignTokens.Palette.accent
                )
                .accessibilityIdentifier(identifier)

            if let detail = status.detail {
                Text(detail)
                    .font(DesignTokens.Typography.captionSub)
                    .foregroundStyle(DesignTokens.Palette.accent)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(detailIdentifier)
            }
        }
    }

    private func localized(_ key: String) -> String {
        String(localized: String.LocalizationValue(key), bundle: localizationBundle)
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppState())
}

/// Visual cue for "this is an editable input field" inside Settings.
/// A filled rounded surface in `bg.primary` floating on the section's
/// `bg.secondary` listRowBackground. See docs/design.md > "Settings
/// 输入控件视觉" for the rationale.
struct InputCardSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, DesignTokens.Spacing.m)
            .padding(.vertical, DesignTokens.Spacing.s + 2)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(DesignTokens.Palette.bgPrimary)
            )
    }
}

extension View {
    func inputCardSurface() -> some View {
        modifier(InputCardSurface())
    }
}
