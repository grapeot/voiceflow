import SwiftUI

struct MainTabView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.localizationBundle) private var localizationBundle

    var body: some View {
        TabView(selection: $appState.selectedTab) {
            NavigationStack {
                RecordView()
            }
                .tabItem {
                    Label {
                        Text(localized("tab.record"))
                    } icon: {
                        // Outline by default; system fills it for the selected
                        // state, which is the only visual confirmation needed.
                        Image(systemName: "mic")
                    }
                        .accessibilityIdentifier("tab.record")
                }
                .tag(AppState.AppTab.record)
                .accessibilityIdentifier("tab.record")
                .toolbarBackground(.ultraThinMaterial, for: .tabBar)

            SettingsView()
                .tabItem {
                    Label {
                        Text(localized("tab.settings"))
                    } icon: {
                        Image(systemName: "gearshape")
                    }
                        .accessibilityIdentifier("tab.settings")
                }
                .tag(AppState.AppTab.settings)
                .accessibilityIdentifier("tab.settings")
                .toolbarBackground(.ultraThinMaterial, for: .tabBar)
        }
        .tint(DesignTokens.Palette.accent)
    }

    private func localized(_ key: String) -> String {
        String(localized: String.LocalizationValue(key), bundle: localizationBundle)
    }
}

#Preview {
    MainTabView()
        .environmentObject(AppState())
}
