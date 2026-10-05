//
//  DownloadListModel.swift
//  DownloadKitUI
//
//  Optional SwiftUI presentation over the DownloadKit core. The model owns no transfers:
//  dropping it, or the view that holds it, never cancels a download.
//

import SwiftUI
import DownloadKit

/// A main-actor list of snapshots for SwiftUI views.
///
/// Feed it from ``DownloadKit/DownloadManager/snapshots()``:
///
/// ```swift
/// .task {
///     for await list in await manager.snapshots() { model.apply(list) }
/// }
/// ```
@available(iOS 15, *)
@MainActor
public final class DownloadListModel: ObservableObject {
    @Published public private(set) var snapshots: [DownloadSnapshot] = []

    public init() {}

    /// Replaces the list with the latest snapshots.
    public func apply(_ snapshots: [DownloadSnapshot]) {
        guard snapshots != self.snapshots else { return }
        self.snapshots = snapshots
    }

    public func snapshot(for id: DownloadID) -> DownloadSnapshot? {
        snapshots.first { $0.id == id }
    }
}
