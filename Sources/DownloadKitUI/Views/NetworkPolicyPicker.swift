//
//  NetworkPolicyPicker.swift
//  DownloadKitUI
//

import SwiftUI
import DownloadKit

/// Picks the manager's default network policy among ``NetworkPolicyChoice`` values and
/// explains what "unmetered" means. A custom policy set by the host is shown as such and is
/// only replaced when the person picks a choice.
///
/// Put it in a `Form` or `List` section. Changing the default resubmits queued, active and
/// waiting items once under the new policy (see ``DownloadKit/DownloadManager/setDefaultPolicy(_:)``).
@available(iOS 15, macOS 12, *)
public struct NetworkPolicyPicker: View {
    @ObservedObject private var model: DownloadListModel
    @Environment(\.downloadStrings) private var strings

    public init(model: DownloadListModel) {
        self.model = model
    }

    public var body: some View {
        Section {
            Picker(strings.text(.policyTitle), selection: selection) {
                ForEach(NetworkPolicyChoice.allCases) { choice in
                    Text(strings.title(choice)).tag(Optional(choice))
                }
                if model.defaultPolicy != nil, model.policyChoice == nil {
                    Text(strings.text(.policyCustom)).tag(Optional<NetworkPolicyChoice>.none)
                }
            }
            .disabled(model.defaultPolicy == nil)
        } footer: {
            Text(strings.text(.policyFooter))
        }
        .task { await model.refreshDefaultPolicy() }
    }

    private var selection: Binding<NetworkPolicyChoice?> {
        Binding {
            model.policyChoice
        } set: { choice in
            guard let choice, choice != model.policyChoice else { return }
            Task { await model.setDefaultPolicy(choice) }
        }
    }
}
