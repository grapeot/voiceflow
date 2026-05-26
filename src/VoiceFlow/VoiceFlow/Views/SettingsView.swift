import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var tokenInput = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("settings.apiToken.placeholder", text: $tokenInput)
                        .textContentType(.password)
                        .accessibilityIdentifier("settings.apiTokenField")

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

                    Button("settings.testConnection") {}
                        .accessibilityIdentifier("settings.testConnectionButton")
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
