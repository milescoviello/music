import AppIntents
import Foundation

/// Siri and Shortcuts.
///
/// App Intents are the one piece of system integration a **free** Apple account can
/// actually have. Widgets, Live Activities and Control Center controls all need App
/// Groups or entitlements that a personal team cannot provision; intents need neither —
/// they are declared in the binary and the system reads them from the installed app.
///
/// Every intent opens the app rather than conforming to `AudioPlaybackIntent`. That
/// protocol allows starting playback without showing UI, but it requires the audio
/// session to come up in an extension context, and a session that fails to activate there
/// fails *silently* — which on a music app means Siri says "OK" and nothing plays. Opening
/// the app is a beat slower and always works.
@MainActor
enum MusicIntentBridge {
    /// The running app, if there is one. Intents cannot be injected into, so this is the
    /// hand-off point — deliberately the only global in the codebase.
    static weak var appState: AppState?

    /// Waits briefly for the app to finish launching when an intent opened it cold.
    static func state() async -> AppState? {
        for _ in 0..<20 {
            if let appState, appState.phase == .ready { return appState }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return appState
    }
}

struct PlayPlaylistIntent: AppIntent {
    static let title: LocalizedStringResource = "Play Playlist"
    static let description = IntentDescription("Plays one of your Navidrome playlists.")
    static let openAppWhenRun = true

    @Parameter(title: "Playlist")
    var playlist: String

    @Parameter(title: "Shuffle", default: false)
    var shuffled: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$playlist)") {
            \.$shuffled
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let appState = await MusicIntentBridge.state() else {
            return .result(dialog: "Music isn't signed in yet.")
        }
        let said = await appState.playPlaylist(named: playlist, shuffled: shuffled)
        return .result(dialog: "\(said)")
    }
}

struct ShuffleLibraryIntent: AppIntent {
    static let title: LocalizedStringResource = "Shuffle My Library"
    static let description = IntentDescription("Plays a random mix from your whole library.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let appState = await MusicIntentBridge.state() else {
            return .result(dialog: "Music isn't signed in yet.")
        }
        let said = await appState.quickPlay(.shuffleLibrary)
        return .result(dialog: "\(said)")
    }
}

struct PlayFavouritesIntent: AppIntent {
    static let title: LocalizedStringResource = "Play My Favourites"
    static let description = IntentDescription("Shuffles the songs you have starred.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let appState = await MusicIntentBridge.state() else {
            return .result(dialog: "Music isn't signed in yet.")
        }
        let said = await appState.quickPlay(.favourites)
        return .result(dialog: "\(said)")
    }
}

/// Heavy Rotation, today's: the songs played most lately. One press of the Action button.
struct PlayHeavyRotationIntent: AppIntent {
    static let title: LocalizedStringResource = "Play Heavy Rotation"
    static let description = IntentDescription("Plays today's Heavy Rotation: the songs you play most lately.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let appState = await MusicIntentBridge.state() else {
            return .result(dialog: "Music isn't signed in yet.")
        }
        let said = await appState.quickPlay(.heavyRotation)
        return .result(dialog: "\(said)")
    }
}

/// One of today's Made for You mixes, by its place on the shelf.
struct PlayMadeForYouIntent: AppIntent {
    static let title: LocalizedStringResource = "Play Made for You"
    static let description = IntentDescription("Plays one of today's Made for You mixes, the first unless told which.")
    static let openAppWhenRun = true

    @Parameter(title: "Mix", description: "Which mix on the shelf, from 1.", default: 1, inclusiveRange: (1, 40))
    var mix: Int

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let appState = await MusicIntentBridge.state() else {
            return .result(dialog: "Music isn't signed in yet.")
        }
        let said = await appState.quickPlay(.madeForYou, mix: mix)
        return .result(dialog: "\(said)")
    }
}

/// The most-played downloads, shuffled: music with no signal at all.
struct ShuffleMostPlayedIntent: AppIntent {
    static let title: LocalizedStringResource = "Shuffle Most Played"
    static let description = IntentDescription("Shuffles the most-played songs kept on the phone, which play offline.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let appState = await MusicIntentBridge.state() else {
            return .result(dialog: "Music isn't signed in yet.")
        }
        let said = await appState.quickPlay(.mostPlayed)
        return .result(dialog: "\(said)")
    }
}

/// Continues whatever was left in the queue. The most useful one in a car.
struct ResumeMusicIntent: AppIntent {
    static let title: LocalizedStringResource = "Resume Music"
    static let description = IntentDescription("Carries on with the current queue.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let appState = await MusicIntentBridge.state() else {
            return .result(dialog: "Music isn't signed in yet.")
        }
        let said = await appState.quickPlay(.resume)
        return .result(dialog: "\(said)")
    }
}

/// Asks Hermes for a playlist without opening a screen first.
///
/// The one intent here that does not start playback: it hands a sentence to the agent and
/// comes back. Deliberately no waiting — the build takes minutes, so the dialog says it is
/// under way and the app shows it when it lands.
struct MakeVibePlaylistIntent: AppIntent {
    static let title: LocalizedStringResource = "Make a Playlist"
    static let description = IntentDescription("Asks Hermes to build a playlist from a description.")
    static let openAppWhenRun = true

    @Parameter(title: "Vibe")
    var vibe: String

    static var parameterSummary: some ParameterSummary {
        Summary("Make a playlist for \(\.$vibe)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let appState = await MusicIntentBridge.state() else {
            return .result(dialog: "Music isn't signed in yet.")
        }
        let said = await appState.makeVibePlaylist(vibe)
        return .result(dialog: "\(said)")
    }
}

// MARK: - Playlists, artists and albums by name

/// A playlist, an artist or an album: what "Play <name> in Navidrome" names. One kind for
/// all three rather than three, because an app has ten App Shortcuts, and one phrase can
/// then reach every one of them; Siri tells them apart by the names it was given
/// (`suggestedEntities`), and asks when one name is two things.
struct LibraryItemEntity: AppEntity {
    enum Kind: String, Sendable {
        case playlist, artist, album
    }

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Music"
    static let defaultQuery = LibraryItemQuery()

    /// "playlist:<id>", "artist:<id>", "album:<id>": the server's id, and which list it
    /// is an id in.
    let id: String
    let name: String
    let detail: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(detail)")
    }

    var kind: Kind? { Kind(rawValue: String(id.prefix { $0 != ":" })) }
    var serverID: String { String(id.drop { $0 != ":" }.dropFirst()) }

    init(_ playlist: Playlist) {
        id = "playlist:\(playlist.id)"
        name = playlist.name
        detail = "Playlist"
    }

    init(_ artist: Artist) {
        id = "artist:\(artist.id)"
        name = artist.name
        detail = "Artist"
    }

    init(_ album: Album) {
        id = "album:\(album.id)"
        name = album.name
        detail = album.artist.map { "Album by \($0)" } ?? "Album"
    }

    @MainActor
    func play(in appState: AppState, shuffled: Bool) async -> String {
        switch kind {
        case .playlist:
            await appState.playlistStore.loadIfNeeded()
            guard let playlist = appState.playlistStore.playlists.first(where: { $0.id == serverID }) else {
                return "I couldn't find the playlist \(name)."
            }
            return await appState.play(playlist, shuffled: shuffled)
        case .artist:
            return await appState.play(Artist(id: serverID, name: name), shuffled: shuffled)
        case .album:
            return await appState.play(Album(id: serverID, name: name), shuffled: shuffled)
        case nil:
            return "I couldn't find \(name)."
        }
    }
}

struct LibraryItemQuery: EntityStringQuery {
    /// What Siri knows by name before anything is said: every playlist, and the most played
    /// artists and albums. Kept to a few dozen of each: it is read whenever the app comes
    /// forward (`updateAppShortcutParameters`), and the whole library is thousands.
    @MainActor
    func suggestedEntities() async throws -> [LibraryItemEntity] {
        guard let appState = await MusicIntentBridge.state() else { return [] }
        await appState.playlistStore.loadIfNeeded()
        let (artists, albums) = await appState.mostPlayedArtistsAndAlbums(limit: 40)
        return appState.playlistStore.playlists.prefix(60).map { LibraryItemEntity($0) }
            + artists.map { LibraryItemEntity($0) }
            + albums.map { LibraryItemEntity($0) }
    }

    /// A name Siri did not know, said when it asked "Which one?": anything in the library.
    @MainActor
    func entities(matching string: String) async throws -> [LibraryItemEntity] {
        guard let appState = await MusicIntentBridge.state() else { return [] }
        await appState.playlistStore.loadIfNeeded()
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let playlists = appState.playlistStore.playlists.filter { $0.name.range(of: string, options: options) != nil }
        let found = try? await appState.client.search(
            query: string, artistCount: 5, albumCount: 10, songCount: 0, scope: appState.scope.scope
        )
        let items = playlists.prefix(5).map { LibraryItemEntity($0) }
            + (found?.artists ?? []).map { LibraryItemEntity($0) }
            + SearchRanking.oneOfEach(found?.albums ?? []).prefix(5).map { LibraryItemEntity($0) }
        // The very name first, whichever kind it is.
        let exact = items.filter { $0.name.compare(string, options: options) == .orderedSame }
        return exact + items.filter { $0.name.compare(string, options: options) != .orderedSame }
    }

    @MainActor
    func entities(for identifiers: [String]) async throws -> [LibraryItemEntity] {
        guard let appState = await MusicIntentBridge.state() else { return [] }
        var found: [LibraryItemEntity] = []
        for identifier in identifiers {
            let parts = identifier.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "playlist":
                await appState.playlistStore.loadIfNeeded()
                if let playlist = appState.playlistStore.playlists.first(where: { $0.id == parts[1] }) {
                    found.append(LibraryItemEntity(playlist))
                }
            case "artist":
                if let detail = try? await appState.client.artistDetail(id: parts[1]) {
                    found.append(LibraryItemEntity(Artist(id: detail.id, name: detail.name)))
                }
            case "album":
                if let detail = try? await appState.client.albumDetail(id: parts[1]) {
                    found.append(LibraryItemEntity(detail.summary))
                }
            default:
                continue
            }
        }
        return found
    }
}

struct PlayLibraryItemIntent: AppIntent {
    static let title: LocalizedStringResource = "Play Playlist, Artist or Album"
    static let description = IntentDescription("Plays a playlist, an artist or an album, by its name.")
    static let openAppWhenRun = true

    @Parameter(title: "Music")
    var item: LibraryItemEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$item)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let appState = await MusicIntentBridge.state() else {
            return .result(dialog: "Music isn't signed in yet.")
        }
        let said = await item.play(in: appState, shuffled: false)
        return .result(dialog: "\(said)")
    }
}

struct ShuffleLibraryItemIntent: AppIntent {
    static let title: LocalizedStringResource = "Shuffle Playlist, Artist or Album"
    static let description = IntentDescription("Shuffles a playlist, an artist or an album, by its name.")
    static let openAppWhenRun = true

    @Parameter(title: "Music")
    var item: LibraryItemEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Shuffle \(\.$item)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let appState = await MusicIntentBridge.state() else {
            return .result(dialog: "Music isn't signed in yet.")
        }
        let said = await item.play(in: appState, shuffled: true)
        return .result(dialog: "\(said)")
    }
}

// MARK: - The song playing

/// A playlist to add the song playing to. Playlists only, unlike `LibraryItemEntity`.
struct PlaylistEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Playlist"
    static let defaultQuery = PlaylistQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct PlaylistQuery: EntityStringQuery {
    @MainActor
    private func playlists() async -> [Playlist] {
        guard let appState = await MusicIntentBridge.state() else { return [] }
        await appState.playlistStore.loadIfNeeded()
        return appState.playlistStore.playlists
    }

    @MainActor
    func suggestedEntities() async throws -> [PlaylistEntity] {
        await playlists().map { PlaylistEntity(id: $0.id, name: $0.name) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [PlaylistEntity] {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return await playlists()
            .filter { $0.name.range(of: string, options: options) != nil }
            .map { PlaylistEntity(id: $0.id, name: $0.name) }
    }

    @MainActor
    func entities(for identifiers: [String]) async throws -> [PlaylistEntity] {
        await playlists()
            .filter { identifiers.contains($0.id) }
            .map { PlaylistEntity(id: $0.id, name: $0.name) }
    }
}

/// What can be done to the song playing, as Siri hears it. The whole of each is its name,
/// so one App Shortcut, "<action> in Navidrome", is all three.
enum SongActionChoice: String, AppEnum {
    case love
    case radio
    case addToPlaylist

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Song Action"
    static let caseDisplayRepresentations: [SongActionChoice: DisplayRepresentation] = [
        .love: DisplayRepresentation(
            title: "Love this song",
            synonyms: ["Like this song", "Heart this song", "Favorite this song", "Favourite this song"]
        ),
        .radio: DisplayRepresentation(
            title: "Start a radio from this song",
            synonyms: ["Start radio from this song", "Play more like this", "Play songs like this"]
        ),
        .addToPlaylist: DisplayRepresentation(
            title: "Add this song to a playlist",
            synonyms: ["Add this to a playlist", "Save this song to a playlist"]
        ),
    ]

    var action: SongAction {
        switch self {
        case .love: return .love
        case .radio: return .radio
        case .addToPlaylist: return .addToPlaylist
        }
    }
}

/// Loves the song playing, starts a radio from it, or adds it to a playlist, without
/// opening the app: the song is already playing, and none of it has anything to show.
struct SongActionIntent: AppIntent {
    static let title: LocalizedStringResource = "Song Playing"
    static let description = IntentDescription("Loves the song playing, starts a radio from it, or adds it to a playlist.")
    static let openAppWhenRun = false

    @Parameter(title: "Action")
    var action: SongActionChoice

    @Parameter(title: "Playlist", description: "For adding the song to a playlist.")
    var playlist: PlaylistEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$action)") {
            \.$playlist
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let appState = await MusicIntentBridge.state() else {
            return .result(dialog: "Music isn't signed in yet.")
        }
        switch action {
        case .radio where !appState.player.isPlaying:
            // Music started from the background with nothing playing fails silently (the
            // top of this file), so a radio waits for something to be playing.
            return .result(dialog: "Start something playing first, then ask again.")
        case .addToPlaylist:
            var chosen = playlist
            if chosen == nil { chosen = try await $playlist.requestValue("Which playlist?") }
            guard let chosen else { return .result(dialog: "Which playlist?") }
            await appState.playlistStore.loadIfNeeded()
            guard let target = appState.playlistStore.playlists.first(where: { $0.id == chosen.id }) else {
                return .result(dialog: "I couldn't find the playlist \(chosen.name).")
            }
            let said = await appState.songAction(.addToPlaylist, playlist: target)
            return .result(dialog: "\(said)")
        default:
            let said = await appState.songAction(action.action)
            return .result(dialog: "\(said)")
        }
    }
}

extension MusicShortcuts {
    @MainActor private static var namesReadAt: Date?

    /// Has Siri read the names it knows again (`LibraryItemQuery.suggestedEntities`): a
    /// playlist made since is then one it knows. At most hourly, as the app comes forward.
    @MainActor
    static func refreshNamesIfStale() {
        if let namesReadAt, Date.now.timeIntervalSince(namesReadAt) < 3600 { return }
        namesReadAt = .now
        updateAppShortcutParameters()
    }
}

/// The phrases Siri accepts without opening Shortcuts first.
///
/// `.applicationName` is **required** in every phrase — Apple will not register a shortcut
/// without it — and it expands to the app name *and* every entry in `INAlternativeAppNames`.
/// That is why those alternates exist: this app is called "Music", so "play my favourites
/// in Music" is heard as Apple Music, and a bare "play X" goes to whichever media app has
/// registered a media intent (Plexamp). Saying "in Navidrome" resolves it unambiguously.
///
/// Bare "play <something>" cannot be captured on a free account: that is `INPlayMediaIntent`
/// in the SiriKit media domain, which needs the Siri capability, which needs a paid team.
/// Plexamp has one, which is exactly why Siri prefers it.
///
/// Ten is the most an app may have, and these are ten: which is why playlists, artists and
/// albums share one entity, and the song actions one enum. `PlayPlaylistIntent` is still
/// there for Shortcuts that use it, without phrases of its own; Play <name> has them.
/// The names Siri knows are read again when the app comes forward
/// (`refreshNamesIfStale`, from `MusicApp`).
struct MusicShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ResumeMusicIntent(),
            phrases: [
                "Resume \(.applicationName)",
                "Keep playing in \(.applicationName)",
                "Continue \(.applicationName)",
            ],
            shortTitle: "Resume",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: PlayHeavyRotationIntent(),
            phrases: [
                "Play Heavy Rotation in \(.applicationName)",
                "Play my heavy rotation in \(.applicationName)",
            ],
            shortTitle: "Heavy Rotation",
            systemImageName: "flame.fill"
        )
        AppShortcut(
            intent: PlayMadeForYouIntent(),
            phrases: [
                "Play Made for You in \(.applicationName)",
                "Play my mix in \(.applicationName)",
            ],
            shortTitle: "Made for You",
            systemImageName: "sparkles.rectangle.stack"
        )
        AppShortcut(
            intent: ShuffleMostPlayedIntent(),
            phrases: [
                "Shuffle my most played in \(.applicationName)",
                "Play my most played in \(.applicationName)",
            ],
            shortTitle: "Most Played",
            systemImageName: "arrow.down.circle.fill"
        )
        AppShortcut(
            intent: ShuffleLibraryIntent(),
            phrases: [
                "Shuffle my library in \(.applicationName)",
                "Shuffle \(.applicationName)",
                "Shuffle my music in \(.applicationName)",
            ],
            shortTitle: "Shuffle Library",
            systemImageName: "shuffle"
        )
        AppShortcut(
            intent: PlayFavouritesIntent(),
            phrases: [
                "Play my favourites in \(.applicationName)",
                "Play my favorites in \(.applicationName)",
            ],
            shortTitle: "Play Favourites",
            systemImageName: "heart.fill"
        )
        AppShortcut(
            intent: MakeVibePlaylistIntent(),
            phrases: [
                "Make a playlist in \(.applicationName)",
                "Build me a playlist in \(.applicationName)",
            ],
            shortTitle: "Make a Playlist",
            systemImageName: "sparkles"
        )
        AppShortcut(
            intent: PlayLibraryItemIntent(),
            phrases: [
                "Play \(\.$item) in \(.applicationName)",
                "Play \(\.$item) on \(.applicationName)",
                "Play a playlist in \(.applicationName)",
                "Play playlist in \(.applicationName)",
            ],
            shortTitle: "Play",
            systemImageName: "music.note.list"
        )
        AppShortcut(
            intent: ShuffleLibraryItemIntent(),
            phrases: [
                "Shuffle \(\.$item) in \(.applicationName)",
                "Shuffle \(\.$item) on \(.applicationName)",
            ],
            shortTitle: "Shuffle",
            systemImageName: "shuffle.circle"
        )
        AppShortcut(
            intent: SongActionIntent(),
            phrases: [
                "\(\.$action) in \(.applicationName)",
                "\(\.$action) on \(.applicationName)",
            ],
            shortTitle: "This Song",
            systemImageName: "heart"
        )
    }
}
