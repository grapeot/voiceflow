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
                        // Pixel-grid mic glyph. Template image: amber when the
                        // tab is selected, gray otherwise — driven by `.tint`.
                        Image.pixelTab(.mic)
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
                        // Pixel-grid gear glyph — matches the mic tab's
                        // template-image treatment (amber selected, gray not).
                        Image.pixelTab(.gear)
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
