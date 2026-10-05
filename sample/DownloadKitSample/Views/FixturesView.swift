//
//  FixturesView.swift
//  DownloadKitSample
//
//  Every fixture with a ready-made download button (tap: download, pause, resume or retry;
//  long press: every action), and the default network policy.
//

import SwiftUI
import DownloadKit
import DownloadKitUI

struct FixturesView: View {
    @EnvironmentObject private var downloads: SampleDownloads
    @EnvironmentObject private var list: DownloadListModel

    var body: some View {
        NavigationView {
            List {
                if downloads.startState == .starting {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Restoring downloads. The screen stays usable; a command sent before the start finishes is refused with a message.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
                if let banner = list.banner {
                    ReconciliationBanner(banner)
                }
                NetworkPolicyPicker(model: list)
                ForEach(groups, id: \.self) { group in
                    Section(group) {
                        ForEach(FixtureCatalog.items.filter { $0.group == group }) { item in
                            FixtureRow(item: item, list: list, downloads: downloads)
                        }
                    }
                }
            }
            .navigationTitle("Fixtures")
        }
        .navigationViewStyle(.stack)
        .task { await list.observe() }
    }

    private var groups: [String] {
        var seen: [String] = []
        for item in FixtureCatalog.items where !seen.contains(item.group) { seen.append(item.group) }
        return seen
    }
}

private struct FixtureRow: View {
    let item: FixtureItem
    @ObservedObject var list: DownloadListModel
    let downloads: SampleDownloads
    @Environment(\.downloadStrings) private var strings

    var body: some View {
        let id = try? DownloadID(item.id)
        let state = id.flatMap(list.item(for:))
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                Text(item.subtitle)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                if let state {
                    Text(strings.status(state.indicator) + (strings.bytes(state).map { " · " + $0 } ?? ""))
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            if let id {
                DownloadButton(model: list, id: id, title: item.title) {
                    await downloads.enqueue(item)
                }
            }
        }
    }
}
