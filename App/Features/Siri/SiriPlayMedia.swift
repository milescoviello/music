import Intents
import UIKit

/// "Hey Siri, play <something>": SiriKit's media intent, handled in the app.
///
/// What the App Shortcuts cannot do (`MusicShortcuts`): a bare "play X", without "in
/// Navidrome", which only an app with Siri's media capability can be offered -- the signing
/// profile has it. Siri still decides which app a bare request goes to, and learns from use;
/// "play X in Navidrome" always reaches this one.
///
/// Siri asks twice. First what the words mean (`resolveMediaItems`): a playlist, an artist,
/// an album or a song of that name, in that order unless it said which kind, as an item
/// with an id. Then to play it (`handle`), answered "in the app": the system wakes the app
/// in the background, with leave to start audio, and hands it the item
/// (`AppDelegate.application(_:handle:completionHandler:)`, then `play`).
final class SiriPlayMedia: NSObject, INPlayMediaIntentHandling {
    /// What a name was found to be, without any of Intents' classes, so it can cross from
    /// the main actor.
    struct Found: Sendable {
        let identifier: String
        let title: String
        let type: INMediaItemType
    }

    func resolveMediaItems(for intent: INPlayMediaIntent) async -> [INPlayMediaMediaItemResolutionResult] {
        let search = intent.mediaSearch
        let query = Query(
            name: search?.mediaName, artist: search?.artistName, album: search?.albumName,
            type: search?.mediaType ?? .unknown, current: search?.reference == .currentlyPlaying
        )
        guard let found = await Self.find(query) else { return [.unsupported()] }
        let item = INMediaItem(identifier: found.identifier, title: found.title, type: found.type, artwork: nil)
        return INPlayMediaMediaItemResolutionResult.successes(with: [item])
    }

    func handle(intent: INPlayMediaIntent) async -> INPlayMediaIntentResponse {
        INPlayMediaIntentResponse(code: .handleInApp, userActivity: nil)
    }

    struct Query: Sendable {
        let name: String?
        let artist: String?
        let album: String?
        let type: INMediaItemType
        let current: Bool
    }

    @MainActor
    static func find(_ query: Query) async -> Found? {
        guard let appState = await MusicIntentBridge.state() else { return nil }
        if query.current { return Found(identifier: "resume", title: "Music", type: .music) }
        let name = (query.name ?? query.album ?? query.artist)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // "Play some music": the library, shuffled.
        guard !name.isEmpty else { return Found(identifier: "library", title: "Your Library", type: .music) }

        func playlist() async -> Found? {
            await appState.findPlaylist(named: name).map { Found(identifier: "playlist:\($0.id)", title: $0.name, type: .playlist) }
        }
        func artist() async -> Found? {
            await appState.findArtist(named: query.artist ?? name).map { Found(identifier: "artist:\($0.id)", title: $0.name, type: .artist) }
        }
        func album() async -> Found? {
            await appState.findAlbum(named: query.album ?? name).map { Found(identifier: "album:\($0.id)", title: $0.name, type: .album) }
        }
        func song() async -> Found? {
            let found = try? await appState.client.search(query: name, artistCount: 0, albumCount: 0, songCount: 20,
                                                          scope: appState.scope.scope)
            let songs = (found?.songs ?? []).filter { song in
                query.artist.map { song.artist?.localizedCaseInsensitiveContains($0) == true } ?? true
            }
            return LibraryFacets.named(name, in: songs, by: \.title).map { Found(identifier: "song:\($0.id)", title: $0.title, type: .song) }
        }

        switch query.type {
        case .playlist: return await playlist()
        case .artist: return await artist()
        case .album: return await album()
        case .song: return await song()
        default:
            // Said without a kind: the likeliest meaning first.
            if let found = await playlist() { return found }
            if query.artist != nil, query.name == nil, let found = await artist() { return found }
            if let found = await artist() { return found }
            if let found = await album() { return found }
            return await song()
        }
    }

    /// What Siri found, played: from the app delegate once the app is awake.
    @MainActor
    static func play(_ identifier: String, shuffled: Bool) async -> Bool {
        guard let appState = await MusicIntentBridge.state() else { return false }
        let parts = identifier.split(separator: ":", maxSplits: 1).map(String.init)
        switch parts.first {
        case "resume":
            _ = await appState.quickPlay(.resume)
        case "library":
            _ = await appState.quickPlay(.shuffleLibrary)
        case "playlist" where parts.count == 2:
            await appState.playlistStore.loadIfNeeded()
            guard let playlist = appState.playlistStore.playlists.first(where: { $0.id == parts[1] }) else { return false }
            _ = await appState.play(playlist, shuffled: shuffled)
        case "artist" where parts.count == 2:
            guard let detail = try? await appState.client.artistDetail(id: parts[1]) else { return false }
            _ = await appState.play(Artist(id: detail.id, name: detail.name), shuffled: shuffled)
        case "album" where parts.count == 2:
            _ = await appState.play(Album(id: parts[1], name: ""), shuffled: shuffled)
        case "song" where parts.count == 2:
            guard let song = try? await appState.client.song(id: parts[1]) else { return false }
            appState.player.play(songs: [song], startingAt: 0, source: "Siri")
        default:
            return false
        }
        return true
    }

    /// Asked once: without it Siri does not offer the app its media requests.
    @MainActor
    static func askForSiriIfNeeded() {
        guard INPreferences.siriAuthorizationStatus() == .notDetermined else { return }
        INPreferences.requestSiriAuthorization { _ in }
    }
}
