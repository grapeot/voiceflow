import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var tokenInput = ""
    @State private var openCodePasswordInput = ""

    var body: some View {
        NavigationStack {
            Form {
                aiBuilderSection
                openCodeSection
            }
            .navigationTitle(Text("tab.settings"))
        }
    }

    private var aiBuilderSection: some View {
        Section(header: Text("settings.aiBuilder.title")) {
            VStack(alignment: .leading, spacing: 8) {
                Text("settings.apiToken.placeholder")
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
                    SecureField("settings.apiToken.placeholder", text: $tokenInput)
                        .textContentType(.password)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .accessibilityIdentifier("settings.apiTokenField")
                }
            }
            .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 8) {
                Text("settings.endpoint.title")
                    .font(.subheadline)
                    .foregroundStyle(.primary)

                Text(appState.aiBuilderEndpoint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings.endpointValue")
            }
            .padding(.vertical, 4)

            HStack {
                Text("settings.apiToken.status")
                    .font(.subheadline)
                Spacer()
                Text(appState.hasSavedAIBuilderToken ? "settings.apiToken.saved" : "settings.apiToken.notSaved")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings.apiTokenStatus")
            }

            HStack {
                Button("settings.apiToken.save") {
                    appState.saveAIBuilderToken(tokenInput)
                    tokenInput = ""
                }
                .buttonStyle(BorderedButtonStyle())
                .disabled(appState.hasSavedAIBuilderToken || tokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("settings.saveTokenButton")

                Spacer()

                Button("settings.apiToken.clear", role: .destructive) {
                    appState.clearAIBuilderToken()
                    tokenInput = ""
                }
                .buttonStyle(BorderedButtonStyle())
                .disabled(!appState.hasSavedAIBuilderToken)
                .accessibilityIdentifier("settings.clearTokenButton")
            }
            .padding(.vertical, 4)

            Button("settings.testConnection") {
                Task { await appState.testAIBuilderConnection() }
            }
            .buttonStyle(BorderedProminentButtonStyle())
            .disabled(!appState.hasSavedAIBuilderToken || appState.connectionStatus == .testing)
            .accessibilityIdentifier("settings.testConnectionButton")

            Text(appState.connectionStatus.localizedText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("settings.connectionStatus")

            Text("settings.apiToken.securityHint")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var openCodeSection: some View {
        Section(header: Text("settings.openCode.title")) {
            VStack(alignment: .leading, spacing: 8) {
                Text("settings.openCode.serverURL")
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                TextField("settings.openCode.serverURL", text: $appState.openCodeServerURL)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("settings.openCodeServerURLField")
            }
            .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 8) {
                Text("settings.openCode.username")
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                TextField("settings.openCode.username", text: $appState.openCodeUsername)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("settings.openCodeUsernameField")
            }
            .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 8) {
                Text("settings.openCode.password")
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
                    SecureField("settings.openCode.password", text: $openCodePasswordInput)
                        .textContentType(.password)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .accessibilityIdentifier("settings.openCodePasswordField")
                }
            }
            .padding(.vertical, 4)

            HStack {
                Text("settings.openCode.status")
                    .font(.subheadline)
                Spacer()
                Text(appState.isOpenCodeConfigured ? "settings.openCode.configured" : "settings.openCode.notConfigured")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings.openCodeStatus")
            }

            HStack {
                Button("settings.openCode.save") {
                    appState.saveOpenCodePassword(openCodePasswordInput)
                    openCodePasswordInput = ""
                }
                .buttonStyle(BorderedButtonStyle())
                .disabled(appState.hasSavedOpenCodePassword || openCodePasswordInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || appState.openCodeServerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || appState.openCodeUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("settings.saveOpenCodeButton")

                Spacer()

                Button("settings.openCode.clear", role: .destructive) {
                    appState.clearOpenCodeConfig()
                    openCodePasswordInput = ""
                }
                .buttonStyle(BorderedButtonStyle())
                .disabled(!appState.hasSavedOpenCodePassword)
                .accessibilityIdentifier("settings.clearOpenCodeButton")
            }
            .padding(.vertical, 4)

            Text("settings.openCode.optionalHint")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppState())
}
