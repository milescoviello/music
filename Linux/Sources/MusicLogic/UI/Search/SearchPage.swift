import CGtk
import Foundation

/// Search, the phone's: recent searches, genres and decades while the field is empty; as
/// you type, one plain list of the top result, playlists, artists, albums, songs and lyric
/// matches; and when nothing matches, the way to ask Hermes to find it or to search the
/// lyrics instead. The field is in the bottom bar, where iOS 26 puts a search tab's
/// (`BottomChrome`); Library | YouTube and the library's scopes are along the top.
@MainActor
enum SearchPage {
    static func make(_ env: Env) -> NavigationPage {
        let app = env.app
        let entry = SearchEntry(placeholder: "Artists, Albums, Songs").searchDelay(300)
        entry.css("ios-search", "bottom-search")
        env.navigation.searchEntry = entry
        let stack = Stack()
        let idle = Bin()
        let results = Bin()
        stack.add(idle, name: "idle")
        stack.add(Spinner().size(32).halign(GTK_ALIGN_CENTER).valign(GTK_ALIGN_START).margin(48), name: "searching")
        stack.add(results, name: "results")
        let hasQuery = Observed(false)

        var generation = 0
        var searchesYouTube = false
        func search(_ text: String) {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            generation += 1
            let current = generation
            hasQuery.value = !trimmed.isEmpty
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

        // The library's scopes while searching, as the phone's search scopes show.
        let scopes = Bin()
        scopes.observe {
            _ = app.scope.generation
            let store = app.scope
            guard store.isSwitchable, hasQuery.value, !searchesYouTube else {
                scopes.child = nil
                return
            }
            scopes.child = Segmented(store.options.map { ($0.cacheKey, $0.shortName) }, selected: store.scope.cacheKey) { key in
                guard let option = store.options.first(where: { $0.cacheKey == key }) else { return }
                store.scope = option
                search(entry.text)
            }.root
        }

        // Library | YouTube, while the sonic service answers (YouTube comes through it) or
        // while YouTube is chosen, so it can be left.
        let sources = Segmented([("library", "Library"), ("youtube", "YouTube")], selected: "library") { key in
            let youtube = key == "youtube"
            guard youtube != searchesYouTube else { return }
            searchesYouTube = youtube
            gtk_search_entry_set_placeholder_text(entry.widget.cast(), youtube ? "Music Videos, Songs" : "Artists, Albums, Songs")
            search(entry.text)
        }.root
        sources.observe { sources.isVisible = app.video.isAvailable || searchesYouTube }

        let top = Box.vertical(spacing: 8) {
            scopes
            sources
        }.margins(top: 2, bottom: 10, start: 16, end: 16)
        let body = Box.vertical(spacing: 0) {
            top
            stack
        }
        body.keep(hasQuery)
        entry.onMap { entry.grabFocus() }
        return Page.make("Search", content: body, clamp: 900, heading: false) { bar in bar.showsTitle(false) }
    }

    /// Ctrl+F: the field takes the keyboard.
    static func focus(_ navigation: Navigation?) {
        guard let navigation, let entry = navigation.searchEntry else { return }
        navigation.open(.search)
        entry.grabFocus()
    }

    private static func idleView(_ env: Env, pick: @escaping @MainActor (String) -> Void) -> Widget {
        let app = env.app
        let body = Box.vertical(spacing: 12).margins(top: 4, bottom: 12)
        let terms = app.recentSearches.terms
        if !terms.isEmpty {
            body.append(Box.horizontal(spacing: 12) {
                Label("Recent", "shelf-title").xalign(0).hexpand()
                Button("Clear", "flat", "see-all") { app.recentSearches.clear() }
            }.margin(horizontal: 16, vertical: 0))
            let list = Box.vertical(spacing: 0)
            for term in terms {
                list.append(Button(child: Box.horizontal(spacing: 12) {
                    Icon(Symbol.icon("clock.arrow.circlepath"), size: 18).css("tertiary-icon")
                    Label(term, "plain-title").xalign(0).ellipsize().hexpand()
                }.margin(horizontal: 16, vertical: 10), "flat", "recent-term") { pick(term) })
            }
            body.append(list)
        }

        body.append(Label("Browse Genres", "shelf-title").xalign(0).margin(horizontal: 16, vertical: 0))
        let genres = Bin().margin(horizontal: 16, vertical: 0)
        body.append(genres)
        let alive = genres.liveness
        Task { @MainActor in
            let list = ((try? await app.client.genres(scope: app.scope.scope)) ?? [])
                .sorted { ($0.albumCount ?? 0) > ($1.albumCount ?? 0) }
            guard alive.isAlive else { return }
            let tiles: [Widget] = list.prefix(30).map { genre in
                Button(child: Label(genre.value, "genre-name").xalign(0.5).lines(2).maxWidthChars(1), "genre-tile") {
                    env.open(.genre(genre.value))
                }
            }
            // Two across on the phone's width, more as the window widens.
            genres.child = TileGrid(tiles, tileWidth: 200, maxColumns: 6).root
        }

        body.append(Label("Browse by Decade", "shelf-title").xalign(0).margins(top: 12, start: 16, end: 16))
        let decades = Box.horizontal(spacing: 12).margin(horizontal: 16, vertical: 0)
        for start in stride(from: 1960, through: 2020, by: 10) {
            decades.append(Button("\(start)s", "decade-pill") { env.open(.decade(start)) })
        }
        let scroller = ScrolledWindow(decades, horizontal: GTK_POLICY_AUTOMATIC, vertical: GTK_POLICY_NEVER).propagatesNaturalHeight()
        gtk_scrolled_window_set_overlay_scrolling(scroller.widget.cast(), 1)
        scroller.css("shelf-scroller")
        Shelf.passesWheelToPage(scroller)
        body.append(scroller)
        return body
    }

    private static func resultsView(_ env: Env, query: String, outcome: SearchService.Outcome?) -> Widget {
        let app = env.app
        let body = Box.vertical(spacing: 0)
        let record: @MainActor () -> Void = { app.recentSearches.record(query) }

        guard let outcome else {
            return StatusPage(
                icon: Symbol.icon("wifi.exclamationmark"),
                title: "Can’t Reach the Server",
                description: "Search needs the server. Downloads are in Library."
            )
        }
        let results = outcome.results
        if outcome.isOffline, outcome.isEmpty {
            return StatusPage(
                icon: Symbol.icon("wifi.exclamationmark"),
                title: "Can’t Reach the Server",
                description: "Nothing downloaded matches “\(query)”."
            )
        }
        guard !outcome.isEmpty else {
            return StatusPage(
                icon: Symbol.icon("magnifyingglass"),
                title: "No Results",
                description: "Nothing in your library matches “\(query)”.",
                child: Box.vertical(spacing: 8) {
                    Button("Ask Hermes to find it", "suggested-action", "pill") { env.open(.requestMusic(query)) }
                    Button("Search lyrics instead", "flat", "see-all") { env.open(.lyricSearch(query)) }
                }.halign(GTK_ALIGN_CENTER)
            )
        }

        func note(_ text: String) {
            body.append(Label(text, "plain-subtitle").xalign(0).margins(top: 4, bottom: 4, start: 16, end: 16))
        }
        func thumb(_ cover: String?, _ name: String, round: Bool = false, playlistID: String? = nil) -> Widget {
            let artwork = ArtworkView(app, size: .thumb, side: 40, shape: round ? .round : .thumb)
            artwork.show(cover, playlistID: playlistID, fallback: name)
            return artwork.root
        }
        func section(_ title: String, _ rows: [(Widget, @MainActor () -> Void)]) {
            guard !rows.isEmpty else { return }
            body.append(PlainList.header(title))
            let list = PlainList.list()
            for (row, action) in rows { list.append(row, activate: action) }
            body.append(list)
        }

        if outcome.isOffline { note("Offline · showing what is downloaded") }
        if let correction = outcome.correction {
            // Said, so a result that is not what was typed is not a mystery.
            note(outcome.isCorrectionOnly ? "Showing results for “\(correction)”" : "Including results for “\(correction)”")
        }
        if outcome.isCorrectionOnly {
            // Nothing matched what was typed: these are the library's nearest words, so
            // asking for it stays a click away, as it is under No Results.
            let list = PlainList.list()
            list.append(PlainList.row(
                leading: Icon(Symbol.icon("arrow.down.heart"), size: 22).css("accent"),
                title: "Ask Hermes to find “\(query)”", minHeight: 52
            )) { env.open(.requestMusic(query)) }
            body.append(list)
        }

        if let top = SearchRanking.topResult(for: outcome.rankedFor, in: results) {
            body.append(PlainList.header("Top Result"))
            let list = PlainList.list()
            switch top {
            case let .artist(artist):
                let artwork = ArtworkView(app, size: .thumb, side: 72, shape: .round)
                artwork.show(artist.coverArt, fallback: artist.name)
                let radio = Button(icon: Symbol.icon("dot.radiowaves.left.and.right"), "flat", "accent-button") {
                    record()
                    app.stations.play(.artistMix(ids: [artist.id], names: [artist.name]))
                }
                radio.tooltip("Play \(artist.name) Radio")
                list.append(PlainList.row(leading: artwork.root, title: artist.name, subtitle: "Artist", trailing: radio,
                                          minHeight: 96, titleClasses: ["top-result-title"])) {
                    record()
                    env.open(.artist(ArtistRef(artist)))
                }
            case let .album(album):
                let artwork = ArtworkView(app, size: .thumb, side: 72, shape: .thumb)
                artwork.show(album.coverArt, fallback: album.name)
                let kind = ["Album", album.artist, album.year.map(String.init)].compactMap { $0 }.joined(separator: " · ")
                let row = PlainList.row(leading: artwork.root, title: album.name, subtitle: kind, minHeight: 96,
                                        titleClasses: ["top-result-title"])
                row.contextMenu { Menus.album(env, album) }
                list.append(row) {
                    record()
                    env.open(.album(AlbumRef(album)))
                }
            case let .song(song):
                body.append(SongList.make(env, [song], source: "Search"))
            }
            if gtk_widget_get_first_child(list.widget) != nil { body.append(list) }
        }

        // The rest in pieces, each once GTK has nothing more pressing: built at once, the
        // page held up the keys typed meanwhile, a second on the 2009 MacBook. A newer
        // search's page takes this one's place, and the pieces stop.
        Task { @MainActor in
            @MainActor func next() async -> Bool {
                await MainLoop.idle()
                return gtk_widget_get_parent(body.widget) != nil
            }
            guard await next() else { return }
            let wanted = query.trimmingCharacters(in: .whitespaces)
            if wanted.count >= 2 {
                let playlists = app.playlistStore.playlists.filter { $0.name.localizedCaseInsensitiveContains(wanted) }
                section("Playlists", playlists.prefix(4).map { playlist in
                    (PlainList.row(leading: thumb(playlist.coverArt, playlist.name, playlistID: playlist.id), title: playlist.name,
                                   subtitle: playlist.songCount.map { "\($0) songs" }, minHeight: 66), {
                        record()
                        env.open(.playlist(PlaylistRef(playlist)))
                    })
                })
            }
            guard await next() else { return }
            section("Artists", results.artists.prefix(4).map { artist in
                (PlainList.row(leading: thumb(artist.coverArt, artist.name, round: true), title: artist.name, minHeight: 66), {
                    record()
                    env.open(.artist(ArtistRef(artist)))
                })
            })
            guard await next() else { return }
            section("Albums", results.albums.prefix(6).map { album in
                let row = PlainList.row(leading: thumb(album.coverArt, album.name), title: album.name, subtitle: album.artist, minHeight: 66)
                row.contextMenu { Menus.album(env, album) }
                return (row, {
                    record()
                    env.open(.album(AlbumRef(album)))
                })
            })
            guard await next() else { return }
            let songs = Array(results.songs.prefix(20))
            if !songs.isEmpty {
                body.append(PlainList.header("Songs"))
                body.append(SongList.make(env, songs, source: "Search"))
            }
            guard await next() else { return }
            if !outcome.lyrics.isEmpty {
                // The song, and the line that matched, so it is plain why it is here.
                section("Lyrics", outcome.lyrics.map { match in
                    let song = match.song
                    let row = PlainList.row(leading: thumb(song.coverArt, song.album ?? song.title), title: song.title,
                                            subtitle: song.artist, detail: "“\(match.line)”", chevron: false, minHeight: 72)
                    row.contextMenu { Menus.song(env, song) }
                    return (row, {
                        record()
                        app.player.play(songs: [song], startingAt: 0, source: "Search")
                    })
                })
            }
            guard await next() else { return }
            let lyrics = PlainList.list()
            lyrics.append(PlainList.row(
                leading: Icon(Symbol.icon("text.magnifyingglass"), size: 22).css("accent"),
                title: "Search lyrics for “\(query)”", minHeight: 52, titleClasses: ["accent"]
            )) { env.open(.lyricSearch(query)) }
            body.append(lyrics.margins(top: 12))
        }
        return body
    }

}
