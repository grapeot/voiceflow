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
            #if os(visionOS)
            // On visionOS the SwiftUI `colorScheme` env defaults to `.dark`
            // regardless of the user's Settings → Appearance preference,
            // and UIKit's trait collection follows suit. Pin the whole
            // app to Light here so the design tokens render the warm
            // paper-white palette that matches Vision Pro's glass UI.
            // (A Settings → Appearance toggle is planned for V0 but not
            // shipped; see docs/design.md.)
            .preferredColorScheme(.light)
            #endif
        }
        #if os(visionOS)
        // Portrait-ish phone-sized window. Avoids the very wide default that
        // makes the long Settings list and the single-column Record view
        // look awkward on Vision Pro.
        .defaultSize(width: 480, height: 900)
        // `.contentSize` removes the Window-style resize handles entirely
        // (no maximize, no manual stretch).
        .windowResizability(.contentSize)
        #endif
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
