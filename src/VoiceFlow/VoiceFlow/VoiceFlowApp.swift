//
//  VoiceFlowApp.swift
//  VoiceFlow
//
//  Created by Yan Wang on 5/26/26.
//

import SwiftUI

@main
struct VoiceFlowApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environmentObject(appState)
        }
    }
}
