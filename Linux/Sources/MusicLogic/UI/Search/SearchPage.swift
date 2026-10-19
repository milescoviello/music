import CGtk
import Foundation

/// Search: recent searches, genres and decades while the field is empty; the top result,
/// matching playlists, artists, albums and songs as you type; and when nothing matches,
/// the way to ask Hermes to find it, or to search lyrics instead.
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
        func search(_ text: String) {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            generation += 1
            let current = generation
            guard trimmed.count >= 2 else {
                stack.visibleName = "idle"
                return
            }
            stack.visibleName = "searching"
            let alive = stack.liveness
            Task { @MainActor in
                let found = try? await app.client.search(query: trimmed, scope: app.scope.scope)
                guard alive.isAlive, current == generation else { return }
                results.child = resultsView(env, query: trimmed, results: found)
                stack.visibleName = "results"
            }
        }
        entry.onSearch { search($0) }
        entry.onActivate { app.recentSearches.record(entry.text) }

        idle.observe {
            _ = app.recentSearches.terms
            _ = app.scope.generation
            idle.child = idleView(env) { term in
                entry.text = term
                search(term)
            }
        }

        let body = Box.vertical(spacing: 12) {
            entry.hexpand()
            stack
        }.margin(horizontal: 12, vertical: 18)
        entry.onMap { entry.grabFocus() }
        return Page.make("Search", content: body) { bar in bar.end(ScopeMenu.make(app)) }
    }

    /// Ctrl+F: the field takes the keyboard.
    static func focus(_ navigation: Navigation?) {
        guard let navigation, let entry = navigation.searchEntry else { return }
        navigation.view.popToRoot()
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

    private static func resultsView(_ env: Env, query: String, results: SearchResult3?) -> Widget {
        let app = env.app
        let body = Box.vertical(spacing: 18)
        let record = { app.recentSearches.record(query) }

        guard let results, !results.isEmpty else {
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

        if let top = SearchRanking.topResult(for: query, in: results) {
            let group = PreferencesGroup("Top Result")
            switch top {
            case let .artist(artist):
                let artwork = ArtworkView(app, size: .thumb, side: 64, shape: .round)
                artwork.show(artist.coverArt, fallback: artist.name)
                let row = ActionRow(artist.name, subtitle: "Artist") {
                    record()
                    env.open(.artist(ArtistRef(artist)))
                }
                row.prefix(artwork.root)
                row.suffix(Button(icon: "network-wireless-symbolic", "flat", "circular") {
                    app.stations.play(.artistMix(ids: [artist.id], names: [artist.name]))
                }.tooltip("Play \(artist.name) Radio").valign(GTK_ALIGN_CENTER))
                group.add(row)
            case let .album(album):
                let artwork = ArtworkView(app, size: .thumb, side: 64, shape: .thumb)
                artwork.show(album.coverArt, fallback: album.name)
                let row = ActionRow(album.name, subtitle: ["Album", album.artist, album.year.map(String.init)].compactMap { $0 }.joined(separator: " · ")) {
                    record()
                    env.open(.album(AlbumRef(album)))
                }
                row.prefix(artwork.root)
                row.contextMenu { Menus.album(env, album) }
                group.add(row)
            case let .song(song):
                group.add(SongList.make(env, [song], source: "Search"))
            }
            body.append(group)
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

        if !results.artists.isEmpty {
            body.append(Shelf.make("Artists", cards: results.artists.prefix(12).map { Cards.artist(env, $0, side: 96) }))
        }
        if !results.albums.isEmpty {
            body.append(Shelf.make("Albums", cards: results.albums.prefix(12).map { Cards.album(env, $0) }))
        }
        if !results.songs.isEmpty {
            body.append(Label("Songs", "shelf-title"))
            body.append(SongList.make(env, Array(results.songs.prefix(20)), source: "Search"))
        }
        body.append(Button("Search lyrics for “\(query)”", icon: "edit-find-symbolic", "flat") {
            env.open(.lyricSearch(query))
        }.halign(GTK_ALIGN_START))
        return body
    }
}
