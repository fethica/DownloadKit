//
//  SampleConfiguration.swift
//  DownloadKitSample
//

import Foundation
import DownloadKit

enum SampleConfiguration {
    /// Stable for the life of the app: the background session is recreated under it at launch.
    static let sessionIdentifier = "com.fethica.downloadkit.sample.transfers"
    /// The storage root is `Application Support/sample/`.
    static let namespace = "sample"
    /// Downloads default to non-cellular, non-expensive networks.
    static let defaultPolicy = NetworkPolicy.unmeteredOnly

    private static let sessionAnyNetworkKey = "sessionAllowsAnyNetwork"

    /// The networks the background session itself may use. Requests narrow it with each item's
    /// policy, so a session limited to unmetered networks cannot honour an item allowed on
    /// cellular. A wider session costs something too: resume data is only used when the session
    /// is no wider than the item's policy. The session is configured once per process, so a
    /// change applies at the next launch.
    static var sessionAllowsAnyNetwork: Bool {
        get { UserDefaults.standard.bool(forKey: sessionAnyNetworkKey) }
        set { UserDefaults.standard.set(newValue, forKey: sessionAnyNetworkKey) }
    }

    static func makeConfiguration() throws -> DownloadConfiguration {
        let sessionAccess: NetworkPolicy = sessionAllowsAnyNetwork ? .anyNetwork : .unmeteredOnly
        return try DownloadConfiguration(
            storageScope: StorageScope(namespace: namespace),
            sessionIdentifier: sessionIdentifier,
            defaultPolicy: defaultPolicy,
            dependencies: DownloadDependencies(
                transport: URLSessionTransport(options: .init(mode: .background, sessionNetworkAccess: sessionAccess)),
                makeIndexStore: SQLiteIndexStore.opener(),
                fileSystem: LocalFileSystem()
            )
        )
    }
}

/// Answers a user retry of an `unauthorized` item (the fixture's expired-link scenario) with
/// the plain file's URL, recorded in the item's metadata at enqueue.
struct FixtureLinkRefresher: URLRefreshing {
    static let refreshKey = "refreshURL"

    func refreshedURL(for id: DownloadID, metadata: DownloadMetadata) async throws -> URL {
        guard let text = metadata.userInfo[Self.refreshKey], let url = URL(string: text) else {
            throw URLError(.userAuthenticationRequired)
        }
        return url
    }
}
