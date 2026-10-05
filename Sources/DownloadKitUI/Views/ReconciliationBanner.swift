//
//  ReconciliationBanner.swift
//  DownloadKitUI
//

import SwiftUI
import DownloadKit

/// Explains a state the person should know about: downloads still being restored, items
/// whose fate could not be confirmed yet, unreadable transfer storage, or a failed start.
/// Read by VoiceOver as one element, title then detail.
@available(iOS 15, macOS 12, *)
public struct ReconciliationBanner: View {
    private let banner: DownloadBanner
    @Environment(\.downloadStrings) private var strings

    public init(_ banner: DownloadBanner) {
        self.banner = banner
    }

    public var body: some View {
        let text = strings.banner(banner)
        HStack(alignment: .top, spacing: 12) {
            if banner == .restoring {
                ProgressView()
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .imageScale(.large)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(text.title).font(.headline)
                Text(text.detail)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text.title)
        .accessibilityValue(text.detail)
    }
}
