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
                        Image(systemName: "mic.fill")
                    }
                        .accessibilityIdentifier("tab.record")
                }
                .tag(AppState.AppTab.record)
                .accessibilityIdentifier("tab.record")

            SettingsView()
                .tabItem {
                    Label {
                        Text(localized("tab.settings"))
                    } icon: {
                        Image(systemName: "gearshape.fill")
                    }
                        .accessibilityIdentifier("tab.settings")
                }
                .tag(AppState.AppTab.settings)
                .accessibilityIdentifier("tab.settings")
        }
    }

    private func localized(_ key: String) -> String {
        String(localized: String.LocalizationValue(key), bundle: localizationBundle)
    }
}

#Preview {
    MainTabView()
        .environmentObject(AppState())
}
