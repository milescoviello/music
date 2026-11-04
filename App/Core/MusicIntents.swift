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
