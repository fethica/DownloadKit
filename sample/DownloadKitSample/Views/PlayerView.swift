//
//  PlayerView.swift
//  DownloadKitSample
//
//  Completed-only local playback. The file is resolved through a lease (the package never
//  fetches here); with "Offline only" on, an item without a validated local file is reported
//  and nothing is fetched. The player is FRadioPlayer, an optional dependency of the sample
//  only: without it this screen explains what is missing.
//

import SwiftUI
import DownloadKit
import DownloadKitUI
#if canImport(FRadioPlayer)
import FRadioPlayer
#endif

@MainActor
final class SamplePlayer: ObservableObject {
    @Published var offlineOnly = true
    @Published private(set) var nowPlaying: String?
    @Published private(set) var message: String?
    private var lease: LocalFileLease?

    #if canImport(FRadioPlayer)
    static let isAvailable = true
    private var player: FRadioPlayer {
        let player = FRadioPlayer.shared
        // Artwork lookups go to the network; a local file must not.
        player.enableArtwork = false
        return player
    }
    #else
    static let isAvailable = false
    #endif

    func play(_ item: FixtureItem, list: DownloadListModel, remoteURL: URL?, log: EventLog) async {
        await stop(list: list)
        guard let id = try? DownloadID(item.id) else { return }
        switch await list.openLocalFile(for: id) {
        case .available(let lease):
            self.lease = lease
            start(lease.url)
            nowPlaying = item.title
            message = "Playing the downloaded file"
            log.record("play \(item.id): local file")
        case .unavailable(let reason):
            let why = Self.describe(reason)
            if offlineOnly || remoteURL == nil {
                message = "\(item.title) is not available offline (\(why)). Nothing was fetched."
                log.record("play \(item.id): offline only, \(why), nothing fetched")
            } else if let remoteURL {
                start(remoteURL)
                nowPlaying = item.title
                message = "No local file (\(why)); playing from the network"
                log.record("play \(item.id): \(why), streaming from the server")
            }
        case .accessFailed:
            message = "The file cannot be read while the device is locked."
            log.record("play \(item.id): file access failed")
        case .failed(let reason):
            message = "Lookup failed: \(reason.rawValue)"
            log.record("play \(item.id): lookup failed, \(reason.rawValue)")
        }
    }

    func stop(list: DownloadListModel) async {
        #if canImport(FRadioPlayer)
        if nowPlaying != nil { player.stop() }
        #endif
        nowPlaying = nil
        if let lease {
            self.lease = nil
            await list.endAccess(lease)
        }
    }

    private func start(_ url: URL) {
        #if canImport(FRadioPlayer)
        player.radioURL = url
        player.play()
        #endif
    }

    static func describe(_ reason: LocalFileUnavailableReason) -> String {
        switch reason {
        case .notDownloaded: return "not downloaded"
        case .inProgress: return "still downloading"
        case .failed(let failure): return "failed, \(failure.kind.rawValue)"
        case .missing: return "file missing"
        case .corrupt: return "file damaged"
        case .removing: return "being removed"
        }
    }
}

struct PlayerView: View {
    @EnvironmentObject private var downloads: SampleDownloads
    @EnvironmentObject private var list: DownloadListModel
    @StateObject private var player = SamplePlayer()
    @Environment(\.downloadStrings) private var strings

    var body: some View {
        NavigationView {
            List {
                if !SamplePlayer.isAvailable {
                    Text("Playback needs the optional FRadioPlayer package. Add it in project.yml and generate the project again.")
                        .foregroundColor(.secondary)
                }
                Section {
                    Toggle("Offline only", isOn: $player.offlineOnly)
                } footer: {
                    Text("Offline only plays validated downloaded files and never fetches. Turn it off to stream an item that is not downloaded.")
                }
                if let message = player.message {
                    Section("Status") {
                        Text(message)
                        if player.nowPlaying != nil {
                            Button("Stop") { Task { await player.stop(list: downloads.list) } }
                        }
                    }
                }
                Section("Audio fixtures") {
                    ForEach(FixtureCatalog.media.filter(\.isAudio)) { item in
                        Button {
                            Task {
                                await player.play(item, list: downloads.list, remoteURL: downloads.server.url(for: item.path), log: downloads.log)
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(item.title).foregroundColor(.primary)
                                    Text(status(of: item)).font(.footnote).foregroundColor(.secondary)
                                }
                                Spacer()
                                Image(systemName: player.nowPlaying == item.title ? "speaker.wave.2.fill" : "play.fill")
                                    .accessibilityHidden(true)
                            }
                        }
                        .disabled(!SamplePlayer.isAvailable)
                        .accessibilityLabel("Play \(item.title)")
                        .accessibilityValue(status(of: item))
                    }
                }
            }
            .navigationTitle("Play")
        }
        .navigationViewStyle(.stack)
        .task { await list.observe() }
    }

    private func status(of item: FixtureItem) -> String {
        guard let id = try? DownloadID(item.id), let state = list.item(for: id) else {
            return strings.status(.notDownloaded)
        }
        return strings.status(state.indicator)
    }
}
