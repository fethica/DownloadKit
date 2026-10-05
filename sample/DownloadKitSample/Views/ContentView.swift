//
//  ContentView.swift
//  DownloadKitSample
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            FixturesView()
                .tabItem { Label("Fixtures", systemImage: "square.and.arrow.down") }
            DownloadsView()
                .tabItem { Label("Downloads", systemImage: "list.bullet") }
            PlayerView()
                .tabItem { Label("Play", systemImage: "play.circle") }
            DeveloperView()
                .tabItem { Label("Developer", systemImage: "wrench.and.screwdriver") }
        }
    }
}
