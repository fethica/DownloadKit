//
//  AppDelegate.swift
//  DownloadKitSample
//
//  The host's part of the background-session contract: one relaunch receiver created with the
//  process, one manager created and started at every launch, and the system's wake forwarded.
//

import UIKit
import DownloadKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Accepts the system's background-session wake from the first moment of the process,
    /// before the manager exists.
    let wakes: BackgroundTransferEvents
    let downloads: SampleDownloads

    override init() {
        let wakes = BackgroundTransferEvents(sessionIdentifiers: [SampleConfiguration.sessionIdentifier])
        self.wakes = wakes
        downloads = SampleDownloads(wakes: wakes, log: EventLog())
        super.init()
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let state = application.applicationState == .background ? "background" : "foreground"
        downloads.log.record("launch (\(state))")
        // Start at every launch: starting recreates the background session under the same
        // identifier, which is what lets the system deliver finished transfers.
        downloads.start()
        return true
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        let log = downloads.log
        log.record("wake received")
        let accepted = wakes.handleEvents(forSession: identifier) {
            log.record("wake handler called")
            completionHandler()
        }
        if accepted {
            log.record("wake handlers waiting: \(wakes.pendingHandlerCount(forSession: identifier))")
        } else {
            // Not this library's session: answer it here.
            log.record("wake for another session answered")
            completionHandler()
        }
    }
}
