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

        await appState.playlistStore.loadIfNeeded()

        // Matched loosely on purpose: dictation will not reproduce a playlist called
        // "When nobody else is listening" exactly, and an exact-match failure would make
        // the feature useless in the one place it matters, which is hands-free.
        let target = appState.playlistStore.playlists.first {
            $0.name.localizedCaseInsensitiveCompare(playlist) == .orderedSame
        } ?? appState.playlistStore.playlists.first {
            $0.name.localizedCaseInsensitiveContains(playlist)
        }

        guard let target else {
            return .result(dialog: "I couldn't find a playlist called \(playlist).")
        }

        // Through the cache, as the playlist screen does, so a playlist kept on the phone
        // plays offline too -- straight from the server, offline answered "is empty".
        // And from the saved copy, only the songs on the phone: one it would have to stream
        // stops the queue when there is no server.
        let (found, isSaved) = await appState.playlist(target.id)
        guard let detail = found else {
            return .result(dialog: "I couldn't reach your library for \(target.name).")
        }
        guard !detail.songs.isEmpty else {
            return .result(dialog: "\(target.name) is empty.")
        }

        appState.player.play(
            songs: isSaved ? appState.playableHere(detail.songs) : detail.songs,
            startingAt: 0,
            source: target.name,
            shuffled: shuffled
        )
        return .result(dialog: "Playing \(target.name).")
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

        let songs = (try? await appState.client.randomSongs(size: 100)) ?? []
        guard !songs.isEmpty else {
            return .result(dialog: "I couldn't reach your library.")
        }

        appState.startRadio(named: "Shuffle", songs: songs)
        return .result(dialog: "Shuffling your library.")
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

        // Through the cache Home fills, so it works offline -- and a failure is said as
        // one, where it used to come out as "you haven't starred anything".
        let client = appState.client
        let scope = appState.scope.scope
        guard let starred: Starred2 = await appState.cached(CacheKey.starred(scope.cacheKey), {
            try await client.starred(scope: scope)
        }) else {
            return .result(dialog: "I couldn't reach your library.")
        }
        let songs = starred.songs
        guard !songs.isEmpty else {
            return .result(dialog: "You haven't starred anything yet.")
        }

        appState.player.play(
            songs: songs, startingAt: 0, source: "Favourites", shuffled: true
        )
        return .result(dialog: "Playing your favourites.")
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
        guard appState.player.hasQueue else {
            return .result(dialog: "There's nothing queued.")
        }

        appState.player.play()
        let title = appState.player.currentSong?.title
        return .result(dialog: title.map { "Playing \($0)." } ?? "Playing.")
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
        guard appState.hermes.isAvailable else {
            return .result(dialog: "Set the Hermes results address in Music's settings first.")
        }

        await appState.playlistStore.loadIfNeeded()
        let name = VibeTitle.unique(
            VibeTitle.sanitised(vibe),
            existing: appState.playlistStore.playlists.map(\.name),
            requestID: UUID()
        )

        let sent = await appState.hermes.startVibe(name: name, vibe: vibe)
        return .result(dialog: sent
            ? "Hermes is building \(name). It'll appear in your playlists shortly."
            : "I couldn't reach Hermes.")
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
            intent: PlayPlaylistIntent(),
            phrases: [
                "Play a playlist in \(.applicationName)",
                "Play playlist in \(.applicationName)",
            ],
            shortTitle: "Play Playlist",
            systemImageName: "music.note.list"
        )
    }
}
