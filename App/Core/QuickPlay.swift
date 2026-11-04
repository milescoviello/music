import Foundation

/// The one-tap starts: Siri, Shortcuts and the Action button on the phone, the launcher's
/// right-click menu and `music --action=NAME` on the desktop. Here once, so both say and
/// do the same.
enum QuickPlay: String, CaseIterable, Sendable {
    case heavyRotation = "play-heavy-rotation"
    case madeForYou = "play-made-for-you"
    case mostPlayed = "shuffle-most-played"
    case shuffleLibrary = "shuffle-library"
    case favourites = "play-favourites"
    case resume = "resume"

    var title: String {
        switch self {
        case .heavyRotation: return "Play Heavy Rotation"
        case .madeForYou: return "Play Made for You"
        case .mostPlayed: return "Shuffle Most Played"
        case .shuffleLibrary: return "Shuffle Library"
        case .favourites: return "Play Favourites"
        case .resume: return "Resume"
        }
    }
}

/// A start with something to say: which mix, which playlist, what to make. What a second
/// launch of the desktop app hands the one already running, as one string.
enum QuickCommand: Equatable, Sendable {
    case play(QuickPlay, mix: Int = 1)
    case playlist(name: String, shuffled: Bool)
    case makePlaylist(vibe: String)

    var encoded: String {
        switch self {
        case let .play(what, mix): return "play\u{1F}\(what.rawValue)\u{1F}\(mix)"
        case let .playlist(name, shuffled): return "playlist\u{1F}\(shuffled ? 1 : 0)\u{1F}\(name)"
        case let .makePlaylist(vibe): return "vibe\u{1F}\(vibe)"
        }
    }

    init?(encoded: String) {
        let parts = encoded.split(separator: "\u{1F}", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        switch parts.first {
        case "play" where parts.count == 3:
            guard let what = QuickPlay(rawValue: parts[1]) else { return nil }
            self = .play(what, mix: Int(parts[2]) ?? 1)
        case "playlist" where parts.count == 3:
            self = .playlist(name: parts[2], shuffled: parts[1] == "1")
        case "vibe" where parts.count == 2:
            self = .makePlaylist(vibe: parts[1])
        default:
            return nil
        }
    }

    var title: String {
        switch self {
        case let .play(what, _): return what.title
        case let .playlist(name, _): return "Play Playlist \(name)"
        case let .makePlaylist(vibe): return "Make a Playlist for \(vibe)"
        }
    }
}

extension AppState {
    /// Starts it, and returns what to say. `mix` counts from 1, for Made for You.
    func quickPlay(_ what: QuickPlay, mix number: Int = 1) async -> String {
        switch what {
        case .heavyRotation:
            await mixes.loadAndWait(appState: self, scope: scope.mixScope)
            guard let mix = mixes.mixes.first(where: { $0.id == "heavy" }) ?? mixes.mixes.first else {
                return "Today's mixes aren't ready. Is the server reachable?"
            }
            player.play(songs: mix.songs, startingAt: 0, source: mix.title)
            return "Playing \(mix.title)."

        case .madeForYou:
            await mixes.loadAndWait(appState: self, scope: scope.mixScope)
            let all = mixes.mixes
            guard !all.isEmpty else { return "Today's mixes aren't ready. Is the server reachable?" }
            let mix = all[min(max(number, 1), all.count) - 1]
            player.play(songs: mix.songs, startingAt: 0, source: mix.title)
            return number > all.count
                ? "There are \(all.count) mixes today, so here's the last: \(mix.title)."
                : "Playing \(mix.title)."

        case .mostPlayed:
            // The downloaded ones, so it plays with no network at all.
            let songs = downloads.catalog.entries.values
                .filter { $0.isMember(of: MostPlayedDownloads.groupID) }
                .map(\.song)
            guard songs.count >= 10 else {
                let fallback = await quickPlay(.heavyRotation)
                return "Your most played aren't downloaded yet. \(fallback)"
            }
            player.play(songs: songs, startingAt: 0, source: MostPlayedDownloads.groupName, shuffled: true)
            return "Shuffling your \(songs.count) most played."

        case .shuffleLibrary:
            let songs = (try? await client.randomSongs(size: 100)) ?? []
            guard !songs.isEmpty else { return "I couldn't reach your library." }
            startRadio(named: "Shuffle", songs: songs)
            return "Shuffling your library."

        case .favourites:
            let client = self.client
            let current = scope.scope
            guard let starred: Starred2 = await cached(CacheKey.starred(current.cacheKey), {
                try await client.starred(scope: current)
            }) else { return "I couldn't reach your library." }
            guard !starred.songs.isEmpty else { return "You haven't starred anything yet." }
            player.play(songs: starred.songs, startingAt: 0, source: "Favourites", shuffled: true)
            return "Playing your favourites."

        case .resume:
            guard player.hasQueue else { return "There's nothing queued." }
            player.play()
            return player.currentSong.map { "Playing \($0.title)." } ?? "Playing."
        }
    }

    func run(_ command: QuickCommand) async -> String {
        switch command {
        case let .play(what, mix): return await quickPlay(what, mix: mix)
        case let .playlist(name, shuffled): return await playPlaylist(named: name, shuffled: shuffled)
        case let .makePlaylist(vibe): return await makeVibePlaylist(vibe)
        }
    }

    /// The playlist called `name`, or failing that the first whose name holds it.
    func playPlaylist(named name: String, shuffled: Bool) async -> String {
        await playlistStore.loadIfNeeded()
        let playlists = playlistStore.playlists
        guard let target = playlists.first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame })
            ?? playlists.first(where: { $0.name.localizedCaseInsensitiveContains(name) })
        else { return "I couldn't find a playlist called \(name)." }

        let (found, isSaved) = await playlist(target.id)
        guard let detail = found else { return "I couldn't reach your library for \(target.name)." }
        guard !detail.songs.isEmpty else { return "\(target.name) is empty." }
        player.play(
            songs: isSaved ? playableHere(detail.songs) : detail.songs,
            startingAt: 0,
            source: target.name,
            shuffled: shuffled
        )
        return "Playing \(target.name)."
    }

    /// Asks Hermes for a playlist from a description.
    func makeVibePlaylist(_ vibe: String) async -> String {
        guard hermes.isAvailable else { return "Set the Hermes results address in Music's settings first." }
        await playlistStore.loadIfNeeded()
        let name = VibeTitle.unique(
            VibeTitle.sanitised(vibe),
            existing: playlistStore.playlists.map(\.name),
            requestID: UUID()
        )
        let sent = await hermes.startVibe(name: name, vibe: vibe)
        return sent
            ? "Hermes is building \(name). It'll appear in your playlists shortly."
            : "I couldn't reach Hermes."
    }
}

extension AppState {
    /// The year's top songs, as songs to play: each fetched by the id of the copy last
    /// played, in the recap's order.
    func playRecap(_ recap: Recap) async -> Bool {
        let ids = history.recap(year: recap.year, limit: 50).topSongs.compactMap(\.songID)
        var found: [Int: Song] = [:]
        await withTaskGroup(of: (Int, Song?).self) { group in
            for (index, id) in ids.enumerated() {
                group.addTask { [client] in (index, try? await client.song(id: id)) }
            }
            for await (index, song) in group { found[index] = song }
        }
        let songs = ids.indices.compactMap { found[$0] }
        guard !songs.isEmpty else { return false }
        player.play(songs: songs, startingAt: 0, source: "Your \(recap.year)")
        return true
    }
}
