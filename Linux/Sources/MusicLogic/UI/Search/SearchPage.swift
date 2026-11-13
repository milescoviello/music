import CGtk
import Foundation

/// Search: recent searches, genres and decades while the field is empty; the top result,
/// matching playlists, artists, albums and songs as you type; and when nothing matches,
/// the way to ask Hermes to find it, or to search lyrics instead. A Library | YouTube
/// switch over it searches YouTube instead: music videos to play, and songs to add.
@MainActor
enum SearchPage {
    static func make(_ env: Env) -> NavigationPage {
        let app = env.app
        let entry = SearchEntry(placeholder: "Artists, Albums, Songs").searchDelay(300)
        env.navigation.searchEntry = entry
        let stack = Stack()
        let idle = Bin()
        let results = Bin()
        stack.add(idle, name: "idle")
        stack.add(Spinner().size(32).halign(GTK_ALIGN_CENTER).valign(GTK_ALIGN_START).margin(48), name: "searching")
        stack.add(results, name: "results")

        var generation = 0
        var searchesYouTube = false
        func search(_ text: String) {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            generation += 1
            let current = generation
            if searchesYouTube {
                // YouTube's side searches for itself, and says so when the field is empty.
                results.child = YouTubeResults.make(env, query: trimmed)
                stack.visibleName = "results"
                return
            }
            // One letter too: a single letter can be a whole title ("Q.").
            guard !trimmed.isEmpty else {
                stack.visibleName = "idle"
                return
            }
            stack.visibleName = "searching"
            let alive = stack.liveness
            Task { @MainActor in
                let found = await app.search.search(trimmed, scope: app.scope.scope)
                guard alive.isAlive, current == generation else { return }
                results.child = resultsView(env, query: trimmed, outcome: found)
                stack.visibleName = "results"
            }
        }
        entry.onSearch { search($0) }
        // The words that put a misspelled search right, if they are missing or a day old.
        app.search.prepare()
        entry.onActivate { app.recentSearches.record(entry.text) }

        idle.observe {
            _ = app.recentSearches.terms
            _ = app.scope.generation
            idle.child = idleView(env) { term in
                entry.text = term
                search(term)
            }
        }

        // Library | YouTube. Shown while the sonic service answers, since YouTube comes
        // through it -- or while YouTube is chosen, so it can be left.
        let library = ToggleButton("Library")
        let youtube = ToggleButton("YouTube")
        youtube.group(with: library)
        library.isActive = true
        Signal.connect(youtube.widget, "toggled") {
            guard youtube.isActive != searchesYouTube else { return }
            searchesYouTube = youtube.isActive
            gtk_search_entry_set_placeholder_text(entry.widget.cast(), searchesYouTube ? "Music Videos, Songs" : "Artists, Albums, Songs")
            search(entry.text)
        }
        let sources = Box.horizontal(spacing: 0) {
            library
            youtube
        }.css("linked").halign(GTK_ALIGN_CENTER)
        sources.observe {
            sources.isVisible = app.video.isAvailable || searchesYouTube
        }

        let body = Box.vertical(spacing: 12) {
            entry.hexpand()
            sources
            stack
        }.margin(horizontal: 12, vertical: 18)
        entry.onMap { entry.grabFocus() }
        return Page.make("Search", content: body) { bar in bar.end(ScopeMenu.make(app)) }
    }

    /// Ctrl+F: the field takes the keyboard.
    static func focus(_ navigation: Navigation?) {
        guard let navigation, let entry = navigation.searchEntry else { return }
        navigation.open(.search)
        entry.grabFocus()
    }

    private static func idleView(_ env: Env, pick: @escaping @MainActor (String) -> Void) -> Widget {
        let app = env.app
        let body = Box.vertical(spacing: 18)
        let terms = app.recentSearches.terms
        if !terms.isEmpty {
            let group = PreferencesGroup("Recent").suffix(Button("Clear", "flat") { app.recentSearches.clear() })
            for term in terms {
                group.add(ActionRow(term, icon: "document-open-recent-symbolic") { pick(term) })
            }
            body.append(group)
        }

        let genres = FlowBox(spacing: 8).columns(min: 2, max: 6).homogeneous()
        let genreGroup = PreferencesGroup("Browse Genres")
        genreGroup.add(genres)
        body.append(genreGroup)
        let alive = genres.liveness
        Task { @MainActor in
            let list = ((try? await app.client.genres(scope: app.scope.scope)) ?? [])
                .sorted { ($0.albumCount ?? 0) > ($1.albumCount ?? 0) }
            guard alive.isAlive else { return }
            for genre in list.prefix(30) {
                genres.append(Button(genre.value, "card-button") { env.open(.genre(genre.value)) }.size(height: 64))
            }
        }

        let decades = Box.horizontal(spacing: 8)
        for start in stride(from: 1960, through: 2020, by: 10) {
            decades.append(Button("\(start)s", "pill") { env.open(.decade(start)) })
        }
        let decadeGroup = PreferencesGroup("Browse by Decade")
        decadeGroup.add(ScrolledWindow(decades, horizontal: GTK_POLICY_AUTOMATIC, vertical: GTK_POLICY_NEVER).propagatesNaturalHeight())
        body.append(decadeGroup)
        return body
    }

    private static func resultsView(_ env: Env, query: String, outcome: SearchService.Outcome?) -> Widget {
        let app = env.app
        let body = Box.vertical(spacing: 18)
        let record: @MainActor () -> Void = { app.recentSearches.record(query) }

        guard let outcome else {
            return StatusPage(
                icon: "network-offline-symbolic",
                title: "Can’t Reach the Server",
                description: "Search needs the server. Downloads are in Library."
            )
        }
        let results = outcome.results
        if outcome.isOffline, outcome.isEmpty {
            return StatusPage(
                icon: "network-offline-symbolic",
                title: "Can’t Reach the Server",
                description: "Nothing downloaded matches “\(query)”."
            )
        }
        guard !outcome.isEmpty else {
            return StatusPage(
                icon: "system-search-symbolic",
                title: "No Results",
                description: "Nothing in your library matches “\(query)”.",
                child: Box.vertical(spacing: 8) {
                    Button("Ask Hermes to Find It", "suggested-action", "pill") { env.open(.requestMusic(query)) }
                    Button("Search Lyrics Instead", "pill") { env.open(.lyricSearch(query)) }
                }.halign(GTK_ALIGN_CENTER)
            )
        }

        if outcome.isOffline {
            body.append(Label("Offline · showing what is downloaded", "caption", "dim").xalign(0))
        }
        if let correction = outcome.correction {
            // Said, so a result that is not what was typed is not a mystery.
            body.append(Label(outcome.isCorrectionOnly
                ? "Showing results for “\(correction)”"
                : "Including results for “\(correction)”", "caption", "dim").xalign(0))
        }
        if outcome.isCorrectionOnly {
            // Nothing matched what was typed, so these are the library's nearest words --
            // for an artist not in the library ("nerio"), something else entirely. Asking
            // for it stays a click away, as it is under No Results.
            body.append(Button("Ask Hermes to Find “\(query)”", "pill") { env.open(.requestMusic(query)) }.halign(GTK_ALIGN_START))
        }

        // The top result as a card, the first songs beside it.
        let top = SearchRanking.topResult(for: outcome.rankedFor, in: results)
        let leading = Array(results.songs.prefix(top == nil ? 0 : 4))
        if let top {
            let songs = Box.vertical(spacing: 6) {
                Label("Songs", "shelf-title").xalign(0)
                SongList.make(env, leading, source: "Search")
            }
            songs.isVisible = !leading.isEmpty
            body.append(Box.horizontal(spacing: 24) {
                Box.vertical(spacing: 6) {
                    Label("Top Result", "shelf-title").xalign(0)
                    topCard(env, top, record: record)
                }
                songs.hexpand()
            })
        }

        if !results.artists.isEmpty {
            body.append(Shelf.make("Artists", cards: results.artists.prefix(12).map { Cards.artist(env, $0, side: 96) }))
        }
        if !results.albums.isEmpty {
            body.append(Shelf.make("Albums", cards: results.albums.prefix(12).map { Cards.album(env, $0) }))
        }
        let wanted = query.trimmingCharacters(in: .whitespaces)
        let playlists = app.playlistStore.playlists.filter { $0.name.localizedCaseInsensitiveContains(wanted) }
        if !playlists.isEmpty {
            let group = PreferencesGroup("Playlists")
            for playlist in playlists.prefix(4) {
                let artwork = ArtworkView(app, size: .thumb, side: 40, shape: .thumb)
                artwork.show(playlist.coverArt, playlistID: playlist.id, fallback: playlist.name)
                let row = ActionRow(playlist.name, subtitle: playlist.songCount.map { "\($0) songs" }) {
                    record()
                    env.open(.playlist(PlaylistRef(playlist)))
                }
                row.prefix(artwork.root)
                group.add(row)
            }
            body.append(group)
        }

        let rest = Array(results.songs.dropFirst(leading.count).prefix(20))
        if !rest.isEmpty {
            body.append(Label(leading.isEmpty ? "Songs" : "More Songs", "shelf-title").xalign(0))
            body.append(SongList.make(env, rest, source: "Search"))
        }
        if !outcome.lyrics.isEmpty {
            // The song, and the line that matched, so it is plain why it is here.
            let group = PreferencesGroup("Lyrics")
            for match in outcome.lyrics {
                let artwork = ArtworkView(app, size: .thumb, side: 40, shape: .thumb)
                artwork.show(match.song.coverArt, fallback: match.song.album ?? match.song.title)
                let row = ActionRow(match.song.title, subtitle: "“\(match.line)” · \(match.song.artist ?? "")") {
                    record()
                    app.player.play(songs: [match.song], startingAt: 0, source: "Search")
                }
                row.prefix(artwork.root)
                let song = match.song
                row.contextMenu { Menus.song(env, song) }
                group.add(row)
            }
            body.append(group)
        }
        body.append(Button("Search lyrics for “\(query)”", icon: "edit-find-symbolic", "flat") {
            env.open(.lyricSearch(query))
        }.halign(GTK_ALIGN_START))
        return body
    }

    /// The top result, large: a click opens it (a song plays), the round button plays it.
    private static func topCard(_ env: Env, _ top: SearchRanking.TopResult, record: @escaping @MainActor () -> Void) -> Widget {
        let app = env.app
        let name: String
        let kind: String
        let artwork: ArtworkView
        let open: @MainActor () -> Void
        let play: @MainActor () -> Void
        switch top {
        case let .artist(artist):
            artwork = ArtworkView(app, size: .card, side: 112, shape: .round)
            artwork.show(artist.coverArt, fallback: artist.name)
            name = artist.name
            kind = "Artist"
            open = { env.open(.artist(ArtistRef(artist))) }
            play = { app.stations.play(.artistMix(ids: [artist.id], names: [artist.name])) }
        case let .album(album):
            artwork = ArtworkView(app, size: .card, side: 112, shape: .card)
            artwork.show(album.coverArt, fallback: album.name)
            name = album.name
            kind = ["Album", album.artist].compactMap { $0 }.joined(separator: " · ")
            open = { env.open(.album(AlbumRef(album))) }
            play = {
                Task {
                    guard let detail = try? await app.client.albumDetail(id: album.id), !detail.songs.isEmpty else { return }
                    env.play(detail.songs, source: album.name)
                }
            }
        case let .song(song):
            artwork = ArtworkView(app, size: .card, side: 112, shape: .card)
            artwork.show(song.coverArt, fallback: song.album ?? song.title)
            name = song.title
            kind = ["Song", song.artist].compactMap { $0 }.joined(separator: " · ")
            open = { env.play([song], source: "Search") }
            play = open
        }
        let content = Box.vertical(spacing: 4) {
            artwork.root.halign(GTK_ALIGN_START).margins(top: 0, bottom: 10, start: 0, end: 0)
            Label(name, "top-name").xalign(0).ellipsize().maxWidthChars(1)
            Label(kind, "top-kind").xalign(0).ellipsize().maxWidthChars(1)
        }
        let card = Button(child: content, "glass", "top-result") {
            record()
            open()
        }
        let playButton = Button(icon: "media-playback-start-symbolic", "circular", "tile-play", "top-play") {
            record()
            play()
        }
        playButton.tooltip("Play").halign(GTK_ALIGN_END).valign(GTK_ALIGN_END).margin(16)
        switch top {
        case let .album(album): card.contextMenu { Menus.album(env, album) }
        case let .song(song): card.contextMenu { Menus.song(env, song) }
        case .artist: break
        }
        return Overlay(card).add(playButton).size(width: 340, height: -1)
    }

}
