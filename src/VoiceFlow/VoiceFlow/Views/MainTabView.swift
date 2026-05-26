import SwiftUI

struct MainTabView: View {
    var body: some View {
        TabView {
            RecordView()
                .tabItem {
                    Label(String(localized: "tab.record"), systemImage: "mic.fill")
                }
                .accessibilityIdentifier("tab.record")

            SettingsView()
                .tabItem {
                    Label(String(localized: "tab.settings"), systemImage: "gearshape.fill")
                }
                .accessibilityIdentifier("tab.settings")
        }
    }
}

#Preview {
    MainTabView()
        .environmentObject(AppState())
}
