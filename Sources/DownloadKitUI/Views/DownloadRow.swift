//
//  DownloadRow.swift
//  DownloadKitUI
//

import SwiftUI
import DownloadKit

/// One row of a downloads list: state indicator, title, subtitle, status line and size, with
/// every available action as a swipe action, a context menu item and a VoiceOver custom
/// action.
///
/// For VoiceOver the row is a single element read as title, subtitle, then status; the
/// actions are in the actions rotor, so the visual button is not a second stop. At
/// accessibility text sizes the status moves under the title instead of being truncated.
@available(iOS 15, macOS 12, *)
public struct DownloadRow: View {
    @ObservedObject private var model: DownloadListModel
    private let item: DownloadItem
    @Environment(\.downloadStrings) private var strings
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(model: DownloadListModel, item: DownloadItem) {
        self.model = model
        self.item = item
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if !dynamicTypeSize.isAccessibilitySize {
                DownloadStatusIndicator(item.indicator)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.body)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Text(statusLine)
                    .font(.footnote)
                    .foregroundColor(isFailure ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let action = item.indicator.primaryAction {
                Button {
                    Task { await model.perform(action, on: item.id) }
                } label: {
                    if dynamicTypeSize.isAccessibilitySize {
                        Text(strings.title(action))
                    } else {
                        Image(systemName: symbol(for: action))
                            .imageScale(.large)
                    }
                }
                .buttonStyle(.borderless)
                .disabled(model.busyItems.contains(item.id))
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(statusLine)
        .modifier(RowActions(model: model, item: item, strings: strings))
    }

    private var statusLine: String {
        let status = strings.status(item.indicator)
        guard let bytes = strings.bytes(item) else { return status }
        return status + " · " + bytes
    }

    private var accessibilityLabel: String {
        [item.title, item.subtitle].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    private var isFailure: Bool {
        if case .failed = item.indicator { return true }
        return false
    }

    private func symbol(for action: DownloadAction) -> String {
        switch action {
        case .pause: return "pause.circle"
        case .resume: return "arrow.down.circle"
        case .cancel: return "xmark.circle"
        case .retry: return "arrow.clockwise.circle"
        case .remove: return "trash"
        }
    }
}

@available(iOS 15, macOS 12, *)
private struct RowActions: ViewModifier {
    let model: DownloadListModel
    let item: DownloadItem
    let strings: DownloadStrings

    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                ForEach(item.indicator.actions.reversed()) { action in
                    button(action)
                }
            }
            .contextMenu {
                ForEach(item.indicator.actions) { action in
                    button(action)
                }
            }
            .modifier(AccessibilityAction(.pause, of: self))
            .modifier(AccessibilityAction(.resume, of: self))
            .modifier(AccessibilityAction(.retry, of: self))
            .modifier(AccessibilityAction(.cancel, of: self))
            .modifier(AccessibilityAction(.remove, of: self))
    }

    private func button(_ action: DownloadAction) -> some View {
        Button(role: action.isDestructive ? .destructive : nil) {
            Task { await model.perform(action, on: item.id) }
        } label: {
            Text(strings.title(action))
        }
        .disabled(model.busyItems.contains(item.id))
    }
}

/// Adds `action` as a named VoiceOver action when the item offers it.
@available(iOS 15, macOS 12, *)
private struct AccessibilityAction: ViewModifier {
    let action: DownloadAction
    let actions: RowActions

    init(_ action: DownloadAction, of actions: RowActions) {
        self.action = action
        self.actions = actions
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if actions.item.indicator.actions.contains(action) {
            content.accessibilityAction(named: Text(actions.strings.label(action, itemTitle: actions.item.title))) {
                let model = actions.model
                let id = actions.item.id
                Task { await model.perform(action, on: id) }
            }
        } else {
            content
        }
    }
}
