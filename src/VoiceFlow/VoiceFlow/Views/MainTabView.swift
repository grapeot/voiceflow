import SwiftUI

struct MainTabView: View {
    @Environment(\.localizationBundle) private var localizationBundle

    var body: some View {
        TabView {
            RecordView()
                .tabItem {
                    Label {
                        Text(localized("tab.record"))
                    } icon: {
                        Image(systemName: "mic.fill")
                    }
                        .accessibilityIdentifier("tab.record")
                }
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
