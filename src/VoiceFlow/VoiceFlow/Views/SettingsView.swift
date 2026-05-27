import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.localizationBundle) private var localizationBundle
    @State private var tokenInput = ""
    @State private var openCodePasswordInput = ""

    var body: some View {
        NavigationStack {
            Form {
                aiBuilderSection
                openCodeSection
                languageSection
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(Text(localized("tab.settings")))
            .dismissKeyboardOnTapOutsideTextInputs()
        }
    }

    private var aiBuilderSection: some View {
        Section(header: Text(localized("settings.aiBuilder.title"))) {
            VStack(alignment: .leading, spacing: 8) {
                Text(localized("settings.apiToken.placeholder"))
                    .font(.subheadline)
                    .foregroundStyle(.primary)

                if appState.hasSavedAIBuilderToken {
                    Text(appState.tokenDisplayValue)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                        )
                        .accessibilityIdentifier("settings.apiTokenMaskedValue")
                } else {
                    SecureField(localized("settings.apiToken.placeholder"), text: $tokenInput)
                        .textContentType(.password)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .accessibilityIdentifier("settings.apiTokenField")
                }
            }
            .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 8) {
                Text(localized("settings.endpoint.title"))
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier("settings.endpointTitle")

                Text(appState.aiBuilderEndpoint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings.endpointValue")
            }
            .padding(.vertical, 4)

            HStack {
                Text(localized("settings.apiToken.status"))
                    .font(.subheadline)
                Spacer()
                Text(localized(appState.hasSavedAIBuilderToken ? "settings.apiToken.saved" : "settings.apiToken.notSaved"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings.apiTokenStatus")
            }

            HStack {
                Button(localized("settings.apiToken.save")) {
                    appState.saveAIBuilderToken(tokenInput)
                    tokenInput = ""
                }
                .buttonStyle(BorderedButtonStyle())
                .disabled(appState.hasSavedAIBuilderToken || tokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("settings.saveTokenButton")

                Spacer()

                Button(localized("settings.apiToken.clear"), role: .destructive) {
                    appState.clearAIBuilderToken()
                    tokenInput = ""
                }
                .buttonStyle(BorderedButtonStyle())
                .disabled(!appState.hasSavedAIBuilderToken)
                .accessibilityIdentifier("settings.clearTokenButton")
            }
            .padding(.vertical, 4)

            Button(localized("settings.testConnection")) {
                Task { await appState.testAIBuilderConnection() }
            }
            .buttonStyle(BorderedProminentButtonStyle())
            .disabled(!appState.hasSavedAIBuilderToken || appState.connectionStatus == .testing)
            .accessibilityIdentifier("settings.testConnectionButton")

            connectionStatusView(
                status: appState.connectionStatus,
                identifier: "settings.connectionStatus",
                detailIdentifier: "settings.connectionStatusDetail"
            )

            Text(localized("settings.apiToken.securityHint"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var openCodeSection: some View {
        Section(header: Text(localized("settings.openCode.title"))) {
            VStack(alignment: .leading, spacing: 8) {
                Text(localized("settings.openCode.serverURL"))
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                TextField(localized("settings.openCode.serverURL"), text: $appState.openCodeServerURL)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("settings.openCodeServerURLField")
            }
            .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 8) {
                Text(localized("settings.openCode.username"))
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                TextField(localized("settings.openCode.username"), text: $appState.openCodeUsername)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("settings.openCodeUsernameField")
            }
            .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 8) {
                Text(localized("settings.openCode.password"))
                    .font(.subheadline)
                    .foregroundStyle(.primary)

                if appState.hasSavedOpenCodePassword {
                    Text(appState.openCodePasswordDisplayValue)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                        )
                        .accessibilityIdentifier("settings.openCodePasswordMaskedValue")
                } else {
                    SecureField(localized("settings.openCode.password"), text: $openCodePasswordInput)
                        .textContentType(.password)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .accessibilityIdentifier("settings.openCodePasswordField")
                }
            }
            .padding(.vertical, 4)

            HStack {
                Text(localized("settings.openCode.status"))
                    .font(.subheadline)
                Spacer()
                Text(localized(appState.isOpenCodeConfigured ? "settings.openCode.configured" : "settings.openCode.notConfigured"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings.openCodeStatus")
            }

            HStack {
                Button(localized("settings.openCode.save")) {
                    appState.saveOpenCodePassword(openCodePasswordInput)
                    openCodePasswordInput = ""
                }
                .buttonStyle(BorderedButtonStyle())
                .disabled(appState.hasSavedOpenCodePassword || openCodePasswordInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || appState.openCodeServerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || appState.openCodeUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("settings.saveOpenCodeButton")

                Spacer()

                Button(localized("settings.openCode.clear"), role: .destructive) {
                    appState.clearOpenCodePassword()
                    openCodePasswordInput = ""
                }
                .buttonStyle(BorderedButtonStyle())
                .disabled(!appState.hasSavedOpenCodePassword)
                .accessibilityIdentifier("settings.clearOpenCodeButton")
            }
            .padding(.vertical, 4)

            Button(localized("settings.openCode.testConnection")) {
                Task { await appState.testOpenCodeConnection() }
            }
            .buttonStyle(BorderedProminentButtonStyle())
            .disabled(!appState.isOpenCodeConfigured || appState.openCodeConnectionStatus == .testing)
            .accessibilityIdentifier("settings.testOpenCodeConnectionButton")

            connectionStatusView(
                status: appState.openCodeConnectionStatus,
                localizedKey: { $0.openCodeLocalizedKey },
                identifier: "settings.openCodeConnectionStatus",
                detailIdentifier: "settings.openCodeConnectionStatusDetail"
            )

            Text(localized("settings.openCode.optionalHint"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var languageSection: some View {
        Section(header: Text(localized("settings.language.title"))) {
            VStack(alignment: .leading, spacing: 8) {
                Text(localized("settings.language.description"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker(localized("settings.language.title"), selection: $appState.appLanguage) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(localized(language.localizedTitleKey))
                            .tag(language)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("settings.languagePicker")
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func connectionStatusView(
        status: ConnectionStatus,
        localizedKey: (ConnectionStatus) -> String = { $0.localizedKey },
        identifier: String,
        detailIdentifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(localized(localizedKey(status)))
                .font(.caption)
                .foregroundStyle(status.detail == nil ? Color.secondary : Color.red)
                .accessibilityIdentifier(identifier)

            if let detail = status.detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.red)
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
