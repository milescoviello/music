import CGtk
import Foundation

/// Plexamp's Artist and Album Mix Builders: search, pick up to eight, play a station of
/// them that keeps going with what is like them.
@MainActor
enum MixBuilder {
    private static let limit = 8

    static func make(_ env: Env, kind: MixBuilderKind) -> NavigationPage {
        let app = env.app
        let entry = SearchEntry(placeholder: kind == .artists ? "Artists" : "Albums").searchDelay(250)
        let chosenList = ListBox()
        let chosenGroup = Box.vertical(spacing: 8) {
            Label("In This Mix", "heading")
            chosenList
        }
        let suggestionsList = ListBox()
        let suggestionsGroup = Box.vertical(spacing: 8) {
            Label("Like These", "heading")
            suggestionsList
        }
        let resultsList = ListBox()
        let hint = StatusPage(
            icon: Icons.named(kind == .artists ? "person.2.wave.2" : "square.stack.3d.up"),
            title: kind == .artists ? "Pick a Few Artists" : "Pick a Few Albums",
            description: "Search, click to add, then play the mix."
        ).compact()

        var chosenArtists: [Artist] = []
        var chosenAlbums: [Album] = []
        var results: (artists: [Artist], albums: [Album]) = ([], [])
        var suggestions: [Artist] = []
        let alive = resultsList.liveness

        func refresh() {
            guard alive.isAlive else { return }
            let hasChoices = kind == .artists ? !chosenArtists.isEmpty : !chosenAlbums.isEmpty
            chosenGroup.isVisible = hasChoices
            hint.isVisible = !hasChoices && entry.text.isEmpty

            // Rebuilt whole: a handful of rows, and the order matters.
            chosenList.removeAll()
            for row in chosenRows() { chosenList.append(row) }
            chosenList.append(ButtonRow("Play Mix", icon: "media-playback-start-symbolic", suggested: true) {
                switch kind {
                case .artists: app.stations.play(.artistMix(ids: chosenArtists.map(\.id), names: chosenArtists.map(\.name)))
                case .albums: app.stations.play(.albumMix(ids: chosenAlbums.map(\.id), names: chosenAlbums.map(\.name)))
                }
            })

            suggestionsGroup.isVisible = kind == .artists && entry.text.isEmpty && !suggestions.isEmpty
            resultsList.removeAll()
            if kind == .artists {
                for artist in entry.text.isEmpty ? [] : results.artists { resultsList.append(artistRow(artist)) }
            } else {
                for album in entry.text.isEmpty ? [] : results.albums { resultsList.append(albumRow(album)) }
            }
            resultsList.isVisible = !entry.text.isEmpty
        }

        func chosenRows() -> [Widget] {
            if kind == .artists {
                return chosenArtists.map { artist in
                    ActionRow(artist.name).suffix(Button(icon: "list-remove-symbolic", "flat", "circular") {
                        chosenArtists.removeAll { $0.id == artist.id }
                        suggest()
                        refresh()
                    }.valign(GTK_ALIGN_CENTER))
                }
            }
            return chosenAlbums.map { album in
                ActionRow(album.name, subtitle: album.artist).suffix(Button(icon: "list-remove-symbolic", "flat", "circular") {
                    chosenAlbums.removeAll { $0.id == album.id }
                    refresh()
                }.valign(GTK_ALIGN_CENTER))
            }
        }

        func artistRow(_ artist: Artist) -> Widget {
            let chosen = chosenArtists.contains { $0.id == artist.id }
            let artwork = ArtworkView(app, size: .thumb, side: 40, shape: .round)
            artwork.show(artist.coverArt, fallback: artist.name)
            let row = ActionRow(artist.name) {
                if chosen {
                    chosenArtists.removeAll { $0.id == artist.id }
                } else if chosenArtists.count < limit {
                    chosenArtists.append(artist)
                }
                suggest()
                refresh()
            }
            row.prefix(artwork.root)
            row.suffix(Icon(chosen ? "object-select-symbolic" : "list-add-symbolic").css(chosen ? "accent" : "dim"))
            return row
        }

        func albumRow(_ album: Album) -> Widget {
            let chosen = chosenAlbums.contains { $0.id == album.id }
            let artwork = ArtworkView(app, size: .thumb, side: 40, shape: .thumb)
            artwork.show(album.coverArt, fallback: album.name)
            let row = ActionRow(album.name, subtitle: album.artist) {
                if chosen {
                    chosenAlbums.removeAll { $0.id == album.id }
                } else if chosenAlbums.count < limit {
                    chosenAlbums.append(album)
                }
                refresh()
            }
            row.prefix(artwork.root)
            row.suffix(Icon(chosen ? "object-select-symbolic" : "list-add-symbolic").css(chosen ? "accent" : "dim"))
            return row
        }

        /// Similar artists to the last one chosen, for when the next pick does not come to mind.
        func suggest() {
            guard let last = chosenArtists.last else {
                suggestions = []
                return
            }
            Task { @MainActor in
                let info = try? await app.client.artistInfo(id: last.id, similarCount: 8)
                let chosen = Set(chosenArtists.map(\.id))
                suggestions = (info?.similarArtists ?? []).filter { !chosen.contains($0.id) }
                guard alive.isAlive else { return }
                suggestionsList.removeAll()
                for artist in suggestions { suggestionsList.append(artistRow(artist)) }
                refresh()
            }
        }

        entry.onSearch { text in
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else {
                results = ([], [])
                refresh()
                return
            }
            Task { @MainActor in
                let found = try? await app.client.search(
                    query: trimmed,
                    artistCount: kind == .artists ? 20 : 0,
                    albumCount: kind == .albums ? 20 : 0,
                    songCount: 0,
                    scope: app.scope.scope
                )
                results = (found?.artists ?? [], found?.albums ?? [])
                refresh()
            }
        }

        let body = Box.vertical(spacing: 18) {
            entry
            chosenGroup
            hint
            suggestionsGroup
            resultsList
        }.margin(horizontal: 12, vertical: 18)
        refresh()
        entry.onMap { entry.grabFocus() }
        return Page.make(kind == .artists ? "Artist Mix Builder" : "Album Mix Builder", content: body)
    }
}

/// Plexamp's Sonic Adventure: from one track to another, through what lies between.
@MainActor
enum SonicAdventure {
    static func make(_ env: Env, start: Song) -> NavigationPage {
        let app = env.app
        let entry = SearchEntry(placeholder: "Where to?").searchDelay(250)
        let fromRow = SongRowView(env, style: .artwork)
        fromRow.bind(start)
        let results = ListBox()
        let alive = results.liveness
        var building = false

        entry.onSearch { text in
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            results.removeAll()
            guard !trimmed.isEmpty else { return }
            Task { @MainActor in
                let found = try? await app.client.search(query: trimmed, artistCount: 0, albumCount: 0, songCount: 30, scope: app.scope.scope)
                guard alive.isAlive else { return }
                results.removeAll()
                for song in (found?.songs ?? []).filter({ $0.id != start.id }) {
                    let row = SongRowView(env, style: .artwork)
                    row.bind(song)
                    let spinner = Spinner().size(16).visible(false)
                    let content = Box.horizontal(spacing: 6) {
                        row.root.hexpand()
                        spinner
                    }
                    results.append(content) {
                        guard !building else { return }
                        building = true
                        spinner.isVisible = true
                        Task { @MainActor in
                            await app.stations.playAdventure(from: start, to: song)
                            building = false
                            guard alive.isAlive else { return }
                            spinner.isVisible = false
                            env.navigation.pop()
                        }
                    }
                }
            }
        }

        let body = Box.vertical(spacing: 18) {
            Label("From", "heading")
            ListBox().append(fromRow.root)
            Label("""
            Plexamp walks a map of how tracks sound. Navidrome has no such map, so the way is \
            found through what your server considers related to each end: tracks near the start, \
            then near both, then near the destination.
            """, "caption", "dim").wrap()
            Label("To", "heading")
            entry
            results
        }.margin(horizontal: 12, vertical: 18)
        entry.onMap { entry.grabFocus() }
        return Page.make("Sonic Adventure", content: body)
    }
}
