//
//  DownloadsView.swift
//  DownloadKitSample
//
//  The ready-made list from DownloadKitUI: sections by group, swipe and context actions,
//  confirmed removal. Leaving the tab ends its subscription; transfers continue.
//

import SwiftUI
import DownloadKitUI

struct DownloadsView: View {
    @EnvironmentObject private var downloads: SampleDownloads

    var body: some View {
        NavigationView {
            DownloadList(model: downloads.list)
                .navigationTitle("Downloads")
        }
        .navigationViewStyle(.stack)
        .task { await downloads.list.observe() }
    }
}
