//
//  DownloadList.swift
//  DownloadKitUI
//

import SwiftUI
import DownloadKit

/// A ready-made downloads list: the reconciliation banner, one section per metadata group
/// (items without a group first appear in their own section), a row per item, removal
/// confirmation and command failures.
///
/// A group's "Remove All" removes the group's explicit members, after confirmation; files are
/// never removed by group or pattern. Observe the model while the list is visible:
/// `.task { await model.observe() }`.
@available(iOS 15, macOS 12, *)
public struct DownloadList: View {
    @ObservedObject private var model: DownloadListModel
    private let groupTitle: (String) -> String
    @Environment(\.downloadStrings) private var strings

    /// - Parameter groupTitle: the section title of a group key; the key itself by default.
    public init(model: DownloadListModel, groupTitle: @escaping (String) -> String = { $0 }) {
        self.model = model
        self.groupTitle = groupTitle
    }

    public var body: some View {
        List {
            if let banner = model.banner {
                Section {
                    ReconciliationBanner(banner)
                }
            }
            if model.items.isEmpty {
                Text(strings.text(.listEmpty))
                    .foregroundColor(.secondary)
            }
            ForEach(model.sections) { section in
                Section {
                    ForEach(section.items) { item in
                        DownloadRow(model: model, item: item)
                    }
                } header: {
                    header(for: section)
                }
            }
        }
        .confirmationDialog(
            removalTitle,
            isPresented: Binding(get: { model.pendingRemoval != nil }, set: { if !$0 { model.cancelRemoval() } }),
            titleVisibility: .visible,
            presenting: model.pendingRemoval
        ) { _ in
            Button(strings.text(.removeConfirm), role: .destructive) {
                Task { await model.confirmRemoval() }
            }
            Button(strings.text(.removeKeep), role: .cancel) {
                model.cancelRemoval()
            }
        } message: { _ in
            Text(strings.text(.removeMessage))
        }
        .alert(
            strings.text(.errorTitle),
            isPresented: Binding(get: { model.lastFailure != nil }, set: { if !$0 { model.lastFailure = nil } }),
            presenting: model.lastFailure
        ) { _ in
            Button(strings.text(.errorDismiss), role: .cancel) { model.lastFailure = nil }
        } message: { failure in
            Text(strings.message(failure.reason))
        }
    }

    private var removalTitle: String {
        guard let title = model.pendingRemoval?.title else { return strings.text(.removeTitleGeneric) }
        return strings.text(.removeTitleFormat, title)
    }

    @ViewBuilder private func header(for section: DownloadSection) -> some View {
        let title = section.group.map(groupTitle) ?? strings.text(.listUngrouped)
        HStack {
            Text(title)
            Spacer(minLength: 8)
            if section.group != nil, section.items.count > 1 {
                Button(strings.text(.removeGroup)) {
                    model.requestRemoval(of: section.items.map(\.id), title: title)
                }
                .font(.footnote)
                .buttonStyle(.borderless)
                .accessibilityLabel(strings.text(.removeGroupFormat, title))
                .accessibilityHint(strings.text(.hintRemove))
            }
        }
    }
}
