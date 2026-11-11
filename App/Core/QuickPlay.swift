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

/// What can be done to the song playing, by voice or from the command line.
enum SongAction: String, CaseIterable, Sendable {
    case love
    case radio
    case addToPlaylist = "add-to-playlist"
}

/// A start with something to say: which mix, which playlist, what to make. What a second
/// launch of the desktop app hands the one already running, as one string.
enum QuickCommand: Equatable, Sendable {
    case play(QuickPlay, mix: Int = 1)
    case playlist(name: String, shuffled: Bool)
    case artist(name: String, shuffled: Bool)
    case album(name: String, shuffled: Bool)
    case makePlaylist(vibe: String)
    /// `playlist`: the name of the one to add to, for `.addToPlaylist`.
    case song(SongAction, playlist: String? = nil)

    var encoded: String {
        switch self {
        case let .play(what, mix): return "play\u{1F}\(what.rawValue)\u{1F}\(mix)"
        case let .playlist(name, shuffled): return "playlist\u{1F}\(shuffled ? 1 : 0)\u{1F}\(name)"
        case let .artist(name, shuffled): return "artist\u{1F}\(shuffled ? 1 : 0)\u{1F}\(name)"
        case let .album(name, shuffled): return "album\u{1F}\(shuffled ? 1 : 0)\u{1F}\(name)"
        case let .makePlaylist(vibe): return "vibe\u{1F}\(vibe)"
        case let .song(action, playlist): return "song\u{1F}\(action.rawValue)\u{1F}\(playlist ?? "")"
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
        case "artist" where parts.count == 3:
            self = .artist(name: parts[2], shuffled: parts[1] == "1")
        case "album" where parts.count == 3:
            self = .album(name: parts[2], shuffled: parts[1] == "1")
        case "vibe" where parts.count == 2:
            self = .makePlaylist(vibe: parts[1])
        case "song" where parts.count == 3:
            guard let action = SongAction(rawValue: parts[1]) else { return nil }
            self = .song(action, playlist: parts[2].isEmpty ? nil : parts[2])
        default:
            return nil
        }
    }

    var title: String {
        switch self {
        case let .play(what, _): return what.title
        case let .playlist(name, _): return "Play Playlist \(name)"
        case let .artist(name, _): return "Play Artist \(name)"
        case let .album(name, _): return "Play Album \(name)"
        case let .makePlaylist(vibe): return "Make a Playlist for \(vibe)"
        case .song(.love, _): return "Love This Song"
        case .song(.radio, _): return "Start a Radio from This Song"
        case let .song(.addToPlaylist, name): return "Add This Song to \(name ?? "a Playlist")"
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
        case let .artist(name, shuffled):
            guard let artist = await findArtist(named: name) else { return "I couldn't find an artist called \(name)." }
            return await play(artist, shuffled: shuffled)
        case let .album(name, shuffled):
            guard let album = await findAlbum(named: name) else { return "I couldn't find an album called \(name)." }
            return await play(album, shuffled: shuffled)
        case let .makePlaylist(vibe): return await makeVibePlaylist(vibe)
        case let .song(action, name):
            guard action == .addToPlaylist else { return await songAction(action) }
            guard let name, let playlist = await findPlaylist(named: name) else {
                return "I couldn't find a playlist called \(name ?? "that")."
            }
            return await songAction(action, playlist: playlist)
        }
    }

    /// The playlist called `name`, or failing that the first whose name holds it.
    func playPlaylist(named name: String, shuffled: Bool) async -> String {
        guard let target = await findPlaylist(named: name) else { return "I couldn't find a playlist called \(name)." }
        return await play(target, shuffled: shuffled)
    }

    func findPlaylist(named name: String) async -> Playlist? {
        await playlistStore.loadIfNeeded()
        return LibraryFacets.named(name, in: playlistStore.playlists, by: \.name)
    }

    func play(_ target: Playlist, shuffled: Bool) async -> String {
        let (found, isSaved) = await playlist(target.id)
        guard let detail = found else { return "I couldn't reach your library for \(target.name)." }
        guard !detail.songs.isEmpty else { return "\(target.name) is empty." }
        player.play(
            songs: isSaved ? playableHere(detail.songs) : detail.songs,
            startingAt: 0,
            source: target.name,
            shuffled: shuffled
        )
        return shuffled ? "Shuffling \(target.name)." : "Playing \(target.name)."
    }

    // MARK: - Artists and albums, by name

    /// The artist called `name` in the library being browsed, by the server's search.
    func findArtist(named name: String) async -> Artist? {
        let found = try? await client.search(query: name, artistCount: 20, albumCount: 0, songCount: 0, scope: scope.scope)
        return LibraryFacets.named(name, in: found?.artists ?? [], by: \.name)
    }

    /// The album called `name`. Of an album held in both folders, the copy played more.
    func findAlbum(named name: String) async -> Album? {
        let found = try? await client.search(query: name, artistCount: 0, albumCount: 30, songCount: 0, scope: scope.scope)
        let albums = (found?.albums ?? []).sorted { ($0.playCount ?? 0) > ($1.playCount ?? 0) }
        return LibraryFacets.named(name, in: albums, by: \.name)
    }

    /// The artist's songs in their page's order (`LibraryFacets.popular`), or shuffled.
    func play(_ artist: Artist, shuffled: Bool) async -> String {
        let client = self.client
        let id = artist.id
        async let chart = try? client.topSongs(artist: artist.name, count: 50)
        async let catalogue: [Song]? = cached(CacheKey.artistSongs(id)) {
            try await client.artistSongs(id: id)
        }
        let songs = LibraryFacets.popular(chart: await chart ?? [], catalogue: await catalogue ?? [])
        guard !songs.isEmpty else { return "I couldn't reach your library for \(artist.name)." }
        player.play(songs: songs, startingAt: 0, source: artist.name, shuffled: shuffled)
        return shuffled ? "Shuffling \(artist.name)." : "Playing \(artist.name)."
    }

    func play(_ album: Album, shuffled: Bool) async -> String {
        guard let detail = try? await client.albumDetail(id: album.id) else {
            return "I couldn't reach your library for \(album.name)."
        }
        guard !detail.songs.isEmpty else { return "\(album.name) is empty." }
        player.play(songs: detail.songs, startingAt: 0, source: detail.name, shuffled: shuffled)
        return shuffled ? "Shuffling \(detail.name)." : "Playing \(detail.name)."
    }

    /// The most played albums and their artists, for Siri to know by name before it is
    /// asked: what a voice is likeliest to ask for.
    func mostPlayedArtistsAndAlbums(limit: Int) async -> (artists: [Artist], albums: [Album]) {
        let albums = (try? await client.mostPlayedAlbums(size: limit * 2, scope: scope.scope)) ?? []
        var seen: Set<String> = []
        var artists: [Artist] = []
        for album in albums {
            guard let id = album.artistId, let name = album.artist, seen.insert(id).inserted else { continue }
            artists.append(Artist(id: id, name: name))
        }
        return (Array(artists.prefix(limit)), Array(albums.prefix(limit)))
    }

    // MARK: - The song playing

    /// Loves the song playing, starts a radio from it, or adds it to `playlist`.
    func songAction(_ action: SongAction, playlist: Playlist? = nil) async -> String {
        guard let song = player.currentSong else { return "Nothing is playing." }
        switch action {
        case .love:
            guard !userState.isStarred(song) else { return "You already love \(song.title)." }
            userState.toggleStar(song)
            return "Loved \(song.title)."
        case .radio:
            let title = "\(song.title) Radio"
            let songs = await radio.mix(seed: song, scope: scope.scope)
            guard !songs.isEmpty else { return "I couldn't make a radio from \(song.title)." }
            startRadio(named: title, songs: songs, station: .radio(seedIDs: [song.id], title: title))
            return "Starting \(title)."
        case .addToPlaylist:
            guard let playlist else { return "Which playlist?" }
            playlistStore.lastMessage = nil
            await playlistStore.add([song], to: playlist)
            return playlistStore.lastMessage.map { "\($0)." } ?? "Added \(song.title) to \(playlist.name)."
        }
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
