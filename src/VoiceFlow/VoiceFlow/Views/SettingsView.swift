import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var tokenInput = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if appState.hasSavedAIBuilderToken {
                        HStack {
                            Text("settings.apiToken.placeholder")
                            Spacer()
                            Text(appState.tokenDisplayValue)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("settings.apiTokenMaskedValue")
                        }
                    } else {
                        SecureField("settings.apiToken.placeholder", text: $tokenInput)
                            .textContentType(.password)
                            .accessibilityIdentifier("settings.apiTokenField")
                    }

                    HStack {
                        Text("settings.apiToken.status")
                        Spacer()
                        Text(appState.hasSavedAIBuilderToken ? "settings.apiToken.saved" : "settings.apiToken.notSaved")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("settings.apiTokenStatus")
                    }

                    HStack {
                        Text("settings.endpoint.title")
                        Spacer()
                        Text(appState.aiBuilderEndpoint)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                            .accessibilityIdentifier("settings.endpointValue")
                    }

                    HStack {
                        Button("settings.apiToken.save") {
                            appState.saveAIBuilderToken(tokenInput)
                            tokenInput = ""
                        }
                        .disabled(appState.hasSavedAIBuilderToken || tokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("settings.saveTokenButton")

                        Button("settings.apiToken.clear", role: .destructive) {
                            appState.clearAIBuilderToken()
                            tokenInput = ""
                        }
                        .disabled(!appState.hasSavedAIBuilderToken)
                        .accessibilityIdentifier("settings.clearTokenButton")
                    }

                    Button("settings.testConnection") {
                        Task { await appState.testAIBuilderConnection() }
                    }
                    .disabled(!appState.hasSavedAIBuilderToken || appState.connectionStatus == .testing)
                    .accessibilityIdentifier("settings.testConnectionButton")

                    Text(appState.connectionStatus.localizedText)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("settings.connectionStatus")
                } header: {
                    Text("settings.aiBuilder.title")
                } footer: {
                    Text("settings.apiToken.securityHint")
                }

                Section {
                    Toggle("settings.openCode.enabled", isOn: $appState.isOpenCodeConfigured)
                        .accessibilityIdentifier("settings.openCodeToggle")

                    Text("settings.openCode.optionalHint")
                        .foregroundStyle(.secondary)
                } header: {
                    Text("settings.openCode.title")
                }
            }
            .navigationTitle(Text("tab.settings"))
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppState())
}
