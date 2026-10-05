//
//  DeveloperView.swift
//  DownloadKitSample
//
//  Scenario switches sent to the fixture server, the manager's status, a debug-only exit to
//  exercise a relaunch, and the redacted event log.
//

import SwiftUI
import DownloadKit
import DownloadKitUI

struct DeveloperView: View {
    @EnvironmentObject private var downloads: SampleDownloads
    @EnvironmentObject private var server: FixtureServerClient
    @EnvironmentObject private var log: EventLog

    @State private var serverResult = ""
    @State private var file = FixtureFile.toneA
    @State private var scenario = FixtureScenario.serverError
    @State private var times = 1
    @State private var reconciliation = ""
    @State private var unreferenced = ""
    @State private var pending = ""
    @State private var wakeHandlers = 0
    @State private var sessionAnyNetwork = SampleConfiguration.sessionAllowsAnyNetwork

    var body: some View {
        NavigationView {
            Form {
                serverSection
                scenarioSection
                statusSection
                sessionSection
                #if DEBUG
                relaunchSection
                #endif
                logSection
            }
            .navigationTitle("Developer")
        }
        .navigationViewStyle(.stack)
        .task { await refresh() }
    }

    private var serverSection: some View {
        Section {
            TextField("Base address", text: $server.baseURLText)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
            Button("Check server") {
                Task { serverResult = await server.check() }
            }
            if !serverResult.isEmpty {
                Text(serverResult).font(.footnote)
            }
        } header: {
            Text("Fixture server")
        } footer: {
            Text("Run the fixture server on a Mac. The simulator reaches it on 127.0.0.1; a device needs the Mac's local network address, printed when the server starts. Changing the address affects new downloads only.")
        }
    }

    private var scenarioSection: some View {
        Section {
            Picker("File", selection: $file) {
                ForEach(FixtureFile.all, id: \.self) { Text($0.name).tag($0) }
            }
            Picker("Scenario", selection: $scenario) {
                ForEach(FixtureScenario.allCases) { scenario in
                    Text(scenario.rawValue).tag(scenario)
                }
            }
            Text(scenario.summary).font(.footnote).foregroundColor(.secondary)
            Stepper(times == 0 ? "Until cleared" : "Next \(times) requests", value: $times, in: 0...10)
            Button("Apply to the file") {
                Task {
                    let result = await server.setScenario(scenario, for: file, times: times)
                    serverResult = result
                    log.record("scenario \(scenario.rawValue) for \(file.name), \(times == 0 ? "until cleared" : "\(times)x"): \(result)")
                }
            }
            Button("Clear every scenario") {
                Task {
                    let result = await server.clearScenarios()
                    serverResult = result
                    log.record("scenarios cleared: \(result)")
                }
            }
        } header: {
            Text("Scenario for the next requests")
        } footer: {
            Text("Applies to the plain files (Fixtures, Tones and Large files). The Scenarios group uses fixed scenario paths instead.")
        }
    }

    private var statusSection: some View {
        Section("Manager") {
            row("Start", startDescription)
            row("Reconciliation", reconciliation)
            row("Wake handlers waiting", String(wakeHandlers))
            row("Unreferenced files", unreferenced)
            row("Pending work", pending)
            Button("Refresh") { Task { await refresh() } }
            Button("Flush pending work") {
                Task {
                    pending = await downloads.flushPendingWork()
                    log.record("flush: \(pending)")
                }
            }
        }
    }

    private var sessionSection: some View {
        Section {
            Toggle("Session may use any network", isOn: $sessionAnyNetwork)
                .onChange(of: sessionAnyNetwork) { value in
                    SampleConfiguration.sessionAllowsAnyNetwork = value
                    log.record("session networks at next launch: \(value ? "any" : "unmetered")")
                }
        } header: {
            Text("Background session")
        } footer: {
            Text("Applies at the next launch. Requests narrow the session's networks with each item's policy, so an item allowed on cellular needs a session that allows it; resume data is only used when the session is no wider than the item's policy.")
        }
    }

    #if DEBUG
    private var relaunchSection: some View {
        Section {
            Button("Exit now", role: .destructive) {
                log.record("exit requested from the developer panel")
                exit(0)
            }
        } header: {
            Text("Relaunch")
        } footer: {
            Text("Debug builds only. Ends the process while transfers run, which the system treats like a termination it caused: transfers continue and the app is relaunched in the background when they finish. Swiping the app away instead cancels them.")
        }
    }
    #endif

    private var logSection: some View {
        Section {
            if log.entries.isEmpty {
                Text("No events").foregroundColor(.secondary)
            }
            ForEach(log.entries.reversed()) { entry in
                Text(entry.text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
            Button("Clear log", role: .destructive) { log.clear() }
        } header: {
            Text("Event log")
        } footer: {
            Text("Kept across launches. URLs and file paths are removed before an event is stored.")
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 12)
            Text(value).foregroundColor(.secondary).multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }

    private var startDescription: String {
        switch downloads.startState {
        case .starting: return "starting"
        case .running: return "running"
        case .failed(let reason): return "failed: \(reason.rawValue)"
        }
    }

    private func refresh() async {
        reconciliation = await downloads.reconciliationDescription()
        unreferenced = await downloads.unreferencedFileCount()
        wakeHandlers = downloads.pendingWakeHandlers
    }
}
