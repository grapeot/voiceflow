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
                        // Standard SF Symbol mic. The TabView fills the symbol
                        // when its tab is selected, so the plain "mic" reads as
                        // "mic.fill" selected and outline otherwise — amber when
                        // selected, gray otherwise via `.tint`.
                        Image(systemName: appState.selectedTab == .record ? "mic.fill" : "mic")
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
                        // Standard SF Symbol gear — matches the mic tab's
                        // selected-fill treatment (amber selected, gray not).
                        Image(systemName: appState.selectedTab == .settings ? "gearshape.fill" : "gearshape")
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
