//
//  ContentView.swift
//  VoiceFlow
//
//  Created by Yan Wang on 5/26/26.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        MainTabView()
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
}
