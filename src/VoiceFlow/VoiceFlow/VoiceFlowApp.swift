//
//  VoiceFlowApp.swift
//  VoiceFlow
//
//  Created by Yan Wang on 5/26/26.
//

import SwiftUI

private struct LocalizationBundleKey: EnvironmentKey {
    static let defaultValue: Bundle = .main
}

extension EnvironmentValues {
    var localizationBundle: Bundle {
        get { self[LocalizationBundleKey.self] }
        set { self[LocalizationBundleKey.self] = newValue }
    }
}

@main
struct VoiceFlowApp: App {
    @StateObject private var appState = AppState()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            localizedRootView
        }
    }

    @ViewBuilder
    private var localizedRootView: some View {
        let root = MainTabView()
            .id(appState.appLanguage.rawValue)
            .environment(\.localizationBundle, appState.appLanguage.bundle)
            .environmentObject(appState)
            .task {
                await appState.consumePendingDeepLinkStartRecordingIfNeeded()
            }
            .onOpenURL { url in
                appState.handleIncomingURL(url)
                Task {
                    await appState.consumePendingDeepLinkStartRecordingIfNeeded()
                }
            }
            .onChange(of: scenePhase) { _, newPhase in
                Task {
                    await appState.handleScenePhaseChange(to: newPhase)
                }
            }

        if let locale = appState.appLanguage.locale {
            root.environment(\.locale, locale)
        } else {
            root
        }
    }
}
