//
//  DownloadButton.swift
//  DownloadKitUI
//

import SwiftUI
import DownloadKit

/// A download control for one item: shows its state and performs the state's primary action
/// on tap (download, pause, resume or retry). A completed item shows its state only; removal
/// is in the context menu and asks for confirmation.
///
/// `download` is called when the item has no record yet; the host builds the request there,
/// because only the host knows the URL, revision and checksum.
@available(iOS 15, macOS 12, *)
public struct DownloadButton: View {
    @ObservedObject private var model: DownloadListModel
    private let id: DownloadID
    private let title: String
    private let download: @MainActor () async -> Void
    @Environment(\.downloadStrings) private var strings

    public init(model: DownloadListModel, id: DownloadID, title: String, download: @escaping @MainActor () async -> Void) {
        self.model = model
        self.id = id
        self.title = title
        self.download = download
    }

    private var item: DownloadItem? { model.item(for: id) }
    private var indicator: DownloadIndicator { item?.indicator ?? .notDownloaded }
    private var isBusy: Bool { model.busyItems.contains(id) }

    public var body: some View {
        Group {
            if indicator == .notDownloaded {
                Button {
                    Task { await download() }
                } label: {
                    DownloadStatusIndicator(indicator)
                }
                .accessibilityLabel(strings.text(.actionDownloadFormat, title))
                .accessibilityHint(strings.text(.hintDownload))
            } else if let action = indicator.primaryAction {
                Button {
                    Task { await model.perform(action, on: id) }
                } label: {
                    DownloadStatusIndicator(indicator)
                }
                .accessibilityLabel(strings.label(action, itemTitle: title))
                .accessibilityHint(strings.hint(action))
            } else {
                DownloadStatusIndicator(indicator)
            }
        }
        .buttonStyle(.borderless)
        .disabled(isBusy)
        .accessibilityValue(strings.status(indicator))
        .contextMenu {
            ForEach(indicator.actions) { action in
                Button(role: action.isDestructive ? .destructive : nil) {
                    Task { await model.perform(action, on: id) }
                } label: {
                    Text(strings.title(action))
                }
            }
        }
    }
}
