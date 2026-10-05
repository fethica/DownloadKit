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

/// Plays one item at a time. The list model owns the playback lease (one at a time, newest
/// request wins, see `DownloadListModel.beginPlayback(of:)`); this type only drives the
/// player and asks the model to end the lease when playback stops, fails or the screen goes
/// away.
@MainActor
final class SamplePlayer: NSObject, ObservableObject {
    @Published var offlineOnly = true
    @Published private(set) var nowPlaying: String?
    @Published private(set) var message: String?
    /// Whether the player plays a leased local file (as opposed to a stream or nothing).
    private var playingLocalFile = false
    private weak var list: DownloadListModel?

    #if canImport(FRadioPlayer)
    static let isAvailable = true
    private var observing = false
    private var player: FRadioPlayer {
        let player = FRadioPlayer.shared
        // Artwork lookups go to the network; a local file must not.
        player.enableArtwork = false
        if !observing {
            observing = true
            player.addObserver(self)
        }
        return player
    }
    #else
    static let isAvailable = false
    #endif

    func play(_ item: FixtureItem, list: DownloadListModel, remoteURL: URL?, log: EventLog) async {
        self.list = list
        stopPlayer()
        guard let id = try? DownloadID(item.id) else { return }
        // `nil`: a later Play or Stop took over while this lookup ran; its lease, if any, is
        // already ended.
        guard let access = await list.beginPlayback(of: id) else { return }
        switch access {
        case .available(let lease):
            start(lease.url, local: true)
            nowPlaying = item.title
            message = "Playing the downloaded file"
            log.record("play \(item.id): local file")
        case .unavailable(let reason):
            let why = Self.describe(reason)
            if offlineOnly || remoteURL == nil {
                message = "\(item.title) is not available offline (\(why)). Nothing was fetched."
                log.record("play \(item.id): offline only, \(why), nothing fetched")
            } else if let remoteURL {
                start(remoteURL, local: false)
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
        stopPlayer()
        await list.endPlayback()
    }

    /// The model ended the playback lease on its own (the item is being removed): the file
    /// may disappear, so the player stops too.
    func playbackLeaseChanged(_ lease: LocalFileLease?) {
        guard lease == nil, playingLocalFile else { return }
        stopPlayer()
        message = "Stopped: the item is being removed"
    }

    private func stopPlayer() {
        #if canImport(FRadioPlayer)
        if nowPlaying != nil { player.stop() }
        #endif
        nowPlaying = nil
        playingLocalFile = false
    }

    private func start(_ url: URL, local: Bool) {
        playingLocalFile = local
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

#if canImport(FRadioPlayer)
extension SamplePlayer: FRadioPlayerObserver {
    /// A player error ends playback and its lease.
    func radioPlayer(_ player: FRadioPlayer, playerStateDidChange state: FRadioPlayer.State) {
        guard state == .error, nowPlaying != nil, let list else { return }
        Task {
            await stop(list: list)
            message = "Playback failed; the file was released"
        }
    }
}
#endif

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
        .onReceive(downloads.list.$playbackLease) { player.playbackLeaseChanged($0) }
        // Leaving the screen ends playback and its lease, so a hidden player never holds a
        // removal.
        .onDisappear { Task { await player.stop(list: downloads.list) } }
    }

    private func status(of item: FixtureItem) -> String {
        guard let id = try? DownloadID(item.id), let state = list.item(for: id) else {
            return strings.status(.notDownloaded)
        }
        return strings.status(state.indicator)
    }
}
