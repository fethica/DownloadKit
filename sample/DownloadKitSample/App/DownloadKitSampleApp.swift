//
//  DownloadKitSampleApp.swift
//  DownloadKitSample
//
//  A small, independent consumer of DownloadKit and DownloadKitUI. It downloads generated
//  fixtures from a fixture server running on a Mac (see sample/fixture-server).
//

import SwiftUI

@main
struct DownloadKitSampleApp: App {
    // The adaptor's delegate exists before the first scene, so the relaunch receiver and the
    // manager are created at every launch, background relaunches included.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appDelegate.downloads)
                .environmentObject(appDelegate.downloads.list)
                .environmentObject(appDelegate.downloads.log)
                .environmentObject(appDelegate.downloads.server)
        }
    }
}
