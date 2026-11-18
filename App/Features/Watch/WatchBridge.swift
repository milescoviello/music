import Foundation
import SwiftUI
import UIKit
import WatchConnectivity

/// The phone's side of the watch app: it tells the watch what is playing and what can be
/// played (`WatchLink.State`), does what the watch asks (play, pause, skip, the heart, a
/// playlist), and sends the songs of a playlist or mix to the watch to keep, each converted
/// to MP3 at 192 kbps -- a FLAC's size on a watch's disk and over its radio would be a
/// waste, and AirPods play nothing better than that anyway.
@MainActor
final class WatchBridge: NSObject {
    static let shared = WatchBridge()

    private weak var appState: AppState?
    private var lastState: WatchLink.State?
    private var lastCoverID: String?
    /// The newest state asked for, sent again when the link comes up or a watch app appears:
    /// one asked for before either would otherwise wait for the next change.
    private var wanted: (state: WatchLink.State, coverID: String?)?
    /// Collections whose songs are still being sent, so a stop can end them.
    private var sending: [String: Task<Void, Never>] = [:]

    private var session: WCSession? {
        guard WCSession.isSupported() else { return nil }
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return nil }
        return session
    }

    func start(appState: AppState) {
        guard WCSession.isSupported(), self.appState == nil else { return }
        self.appState = appState
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Whenever something the watch shows changes. Only a changed state is sent.
    func publish(_ state: WatchLink.State, coverID: String?) async {
        wanted = (state, coverID)
        guard let session, state != lastState || coverID != lastCoverID else { return }
        var context: [String: Any] = [:]
        guard let data = WatchLink.encode(state) else { return }
        context[WatchLink.stateKey] = data
        if coverID != lastCoverID, let appState, let coverID,
           let image = await appState.artwork.image(for: coverID, size: .thumb),
           let jpeg = WidgetPublisher.jpeg(image, side: 160) {
            context[WatchLink.coverKey] = jpeg
        } else if let lastContext = session.applicationContext[WatchLink.coverKey] {
            context[WatchLink.coverKey] = lastContext
        }
        lastState = state
        lastCoverID = coverID
        try? session.updateApplicationContext(context)
    }

    fileprivate func republish() async {
        lastState = nil
        lastCoverID = nil
        if let wanted { await publish(wanted.state, coverID: wanted.coverID) }
    }

    // MARK: - Commands

    func handle(_ command: WatchLink.Command) async {
        guard let appState else { return }
        let player = appState.player
        switch command {
        case .toggle: player.togglePlayPause()
        case .next: player.next()
        case .previous: player.previous()
        case .favourite:
            if let song = player.currentSong { appState.userState.toggleStar(song) }
        case let .rate(value):
            if let song = player.currentSong {
                let current = appState.userState.rating(id: song.id, serverValue: song.userRating)
                appState.userState.setRating(song, to: value, current: current)
            }
        case let .play(item):
            await play(item, on: appState)
        case let .keep(item):
            keep(item)
        case let .stopKeeping(id):
            sending[id]?.cancel()
            sending[id] = nil
            for transfer in WCSession.default.outstandingFileTransfers
            where WatchLink.decode(WatchLink.Track.self, from: transfer.file.metadata?[WatchLink.trackKey])?.collection == id {
                transfer.cancel()
            }
        }
    }

    private func songs(for item: WatchLink.Item, on appState: AppState) async -> [Song] {
        switch item.kind {
        case .mix:
            return appState.mixes.mixes.first { $0.id == item.id }?.songs ?? []
        case .playlist:
            return await appState.playlist(item.id).detail?.songs ?? []
        }
    }

    private func play(_ item: WatchLink.Item, on appState: AppState) async {
        let songs = await songs(for: item, on: appState)
        guard !songs.isEmpty else { return }
        appState.player.play(songs: songs, startingAt: 0, source: item.name)
    }

    // MARK: - Keeping songs on the watch

    /// One song at a time: fetched converted, then handed to WatchConnectivity, which
    /// delivers it whenever the watch is near enough -- over Wi-Fi when it can.
    private func keep(_ item: WatchLink.Item) {
        guard let appState, sending[item.id] == nil else { return }
        sending[item.id] = Task { [weak self] in
            let songs = await self?.songs(for: item, on: appState) ?? []
            for (index, song) in songs.enumerated() {
                if Task.isCancelled { break }
                guard let signer = appState.signer,
                      let url = signer.url("stream.view", ["id": song.id, "format": "mp3", "maxBitRate": "192"])
                else { continue }
                guard let fetched = await Self.fetch(url), (fetched.1 as? HTTPURLResponse)?.statusCode == 200 else { continue }
                let file = fetched.0
                let kept = FileManager.default.temporaryDirectory
                    .appendingPathComponent("watch-\(song.id).mp3")
                try? FileManager.default.removeItem(at: kept)
                guard (try? FileManager.default.moveItem(at: file, to: kept)) != nil else { continue }
                let track = WatchLink.Track(
                    id: song.id, title: song.title, artist: song.artist, album: song.album,
                    duration: Double(song.duration ?? 0), collection: item.id, collectionName: item.name,
                    index: index, total: songs.count
                )
                guard let data = WatchLink.encode(track), WCSession.isSupported() else { continue }
                WCSession.default.transferFile(kept, metadata: [WatchLink.trackKey: data])
            }
            self?.sending[item.id] = nil
        }
    }
}

extension WatchBridge {
    /// A converted song, to a file of its own; nil when the server could not be reached.
    nonisolated static func fetch(_ url: URL) async -> (URL, URLResponse)? {
        try? await URLSession.shared.download(from: url)
    }
}

extension WatchBridge: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        // A watch that has just appeared gets the state at once, not at the next change.
        Task { @MainActor in await WatchBridge.shared.republish() }
    }

    /// The watch app installed, or a watch paired.
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in await WatchBridge.shared.republish() }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // A different watch was paired: talk to it.
        session.activate()
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let command = WatchLink.decode(WatchLink.Command.self, from: message[WatchLink.commandKey]) else { return }
        Task { @MainActor in await WatchBridge.shared.handle(command) }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        let command = WatchLink.decode(WatchLink.Command.self, from: message[WatchLink.commandKey])
        replyHandler([:])
        guard let command else { return }
        Task { @MainActor in await WatchBridge.shared.handle(command) }
    }

    /// Keeping a playlist is queued by the watch (`transferUserInfo`) rather than sent
    /// now, so it reaches the phone whenever the two are next in touch.
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let command = WatchLink.decode(WatchLink.Command.self, from: userInfo[WatchLink.commandKey]) else { return }
        Task { @MainActor in await WatchBridge.shared.handle(command) }
    }

    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        // Sent, or given up on: either way the phone's copy has done its job.
        try? FileManager.default.removeItem(at: fileTransfer.file.fileURL)
    }
}

/// Starts the bridge and sends the watch the state whenever something it shows changes.
private struct WatchBridgeModifier: ViewModifier {
    @Environment(AppState.self) private var appState
    @Environment(PlaylistStore.self) private var playlistStore

    func body(content: Content) -> some View {
        content
            .task { WatchBridge.shared.start(appState: appState) }
            .task(id: key) {
                await WatchBridge.shared.publish(state, coverID: appState.player.currentSong?.coverArt)
            }
    }

    private var arranged: (pinned: [Playlist], rest: [Playlist]) {
        appState.playlistArrangement.arranged(playlistStore.playlists)
    }

    private func item(_ playlist: Playlist) -> WatchLink.Item {
        WatchLink.Item(kind: .playlist, id: playlist.id, name: playlist.name,
                       detail: playlist.songCount.map { "\($0) songs" })
    }

    private var state: WatchLink.State {
        let player = appState.player
        var state = WatchLink.State()
        if let song = player.currentSong {
            state.title = song.title
            state.artist = song.artist
            state.album = song.album
            state.isPlaying = player.isPlaying
            state.elapsed = player.elapsedNow
            state.duration = player.duration
            state.anchor = .now
            state.rating = appState.userState.rating(id: song.id, serverValue: song.userRating)
            state.isFavourite = appState.userState.isStarred(id: song.id, serverValue: song.isFavorite)
        }
        state.pinned = arranged.pinned.map(item)
        state.playlists = arranged.rest.prefix(40).map(item)
        state.mixes = appState.mixes.mixes.map { WatchLink.Item(kind: .mix, id: $0.id, name: $0.title, detail: $0.subtitle) }
        return state
    }

    /// Everything the state shows except the clock, as one value.
    private var key: String {
        let player = appState.player
        let song = player.currentSong
        return [
            song?.id ?? "",
            String(player.isPlaying),
            String(Int(player.duration)),
            song.map { String(appState.userState.rating(id: $0.id, serverValue: $0.userRating)) } ?? "",
            song.map { String(appState.userState.isStarred(id: $0.id, serverValue: $0.isFavorite)) } ?? "",
            playlistStore.playlists.map(\.id).joined(separator: ","),
            appState.playlistArrangement.pinned.joined(separator: ","),
            appState.mixes.mixes.map(\.id).joined(separator: ","),
        ].joined(separator: "|")
    }
}

extension View {
    /// The phone's side of the watch app; attach once, at the root.
    func watchBridge() -> some View {
        modifier(WatchBridgeModifier())
    }
}
