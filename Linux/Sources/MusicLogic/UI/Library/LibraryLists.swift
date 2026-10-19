import CGtk
import Foundation

/// A grid of albums already in hand: a facet, an artist's "See All", a record label.
@MainActor
enum AlbumCollection {
    static func make(_ env: Env, title: String, albums: [Album]) -> NavigationPage {
        Page.make(title, content: grid(env, albums), scrolls: false, clamp: nil)
    }

    static func grid(_ env: Env, _ albums: [Album], empty: String = "No Albums") -> Widget {
        guard !albums.isEmpty else { return Loader.empty(empty, icon: "media-optical-symbolic") }
        let grid = Cards.albumGrid(env)
        grid.set(albums)
        return ScrolledWindow(grid.view).vexpand()
    }
}

/// Genres by how many albums each has, with Genre Radio in each row's menu.
@MainActor
enum GenreList {
    static func make(_ env: Env) -> NavigationPage {
        let app = env.app
        let loader = Loader()
        func radio(_ genre: String) {
            Task {
                let mix = await app.radio.genreMix(genre, scope: app.scope.scope)
                app.startRadio(named: "\(genre) Radio", songs: mix, station: .genre(genre))
            }
        }
        loader.bin.observe {
            let scope = app.scope.scope
            _ = app.scope.generation
            loader.run({ () -> [Genre]? in
                let client = app.client
                app.beginLoadPass()
                return await app.cached(CacheKey.genres(scope.cacheKey)) { try await client.genres(scope: scope) }
            }) { genres in
                let list = ListBox()
                for genre in genres.sorted(by: { ($0.albumCount ?? 0) > ($1.albumCount ?? 0) }) {
                    let row = ActionRow(genre.value) { env.open(.genre(genre.value)) }
                    row.suffix(Label(genre.albumCount.map(String.init) ?? "", "song-meta")).chevron()
                    row.contextMenu { Menu([[.action("Genre Radio") { radio(genre.value) }]]) }
                    list.append(row)
                }
                if genres.isEmpty { return Loader.empty("No Genres", icon: "applications-multimedia-symbolic") }
                return list.margin(horizontal: 12, vertical: 24)
            }
        }
        return Page.make("Genres", content: loader.bin) { bar in bar.end(ScopeMenu.make(app)) }
    }
}

/// A genre: its albums or its songs, and Genre Radio.
@MainActor
enum GenrePage {
    static func make(_ env: Env, genre: String) -> NavigationPage {
        let app = env.app
        let stack = Stack()
        let albumsContent = AlbumList.embedded(env, genre: genre)
        stack.add(albumsContent, name: "albums")
        stack.add(songs(env, genre: genre), name: "songs")

        let albums = ToggleButton("Albums")
        let songsButton = ToggleButton("Songs")
        songsButton.group(with: albums)
        albums.isActive = true
        Signal.connect(albums.widget, "toggled") { if albums.isActive { stack.visibleName = "albums" } }
        Signal.connect(songsButton.widget, "toggled") { if songsButton.isActive { stack.visibleName = "songs" } }
        let switcher = Box.horizontal {
            albums
            songsButton
        }.css("linked")

        let radio = Button(icon: "network-wireless-symbolic", "flat") {
            Task {
                let mix = await app.radio.genreMix(genre, scope: app.scope.scope)
                app.startRadio(named: "\(genre) Radio", songs: mix, station: .genre(genre))
            }
        }.tooltip("Genre Radio")
        let toolbar = ToolbarView(content: stack.vexpand()).top(HeaderBar().title(switcher).end(radio))
        return NavigationPage(toolbar, title: genre)
    }

    /// The genre's songs, a hundred at a time as the list scrolls.
    private static func songs(_ env: Env, genre: String) -> Widget {
        let app = env.app
        let list = SongList.long(env, source: genre)
        var songs: [Song] = []
        var loading = false
        var more = true
        let scroller = ScrolledWindow(list.view).vexpand()
        let alive = scroller.liveness
        func loadMore() {
            guard !loading, more else { return }
            loading = true
            let offset = songs.count
            Task { @MainActor in
                let page = (try? await app.client.songsByGenre(genre, count: 100, offset: offset, scope: app.scope.scope)) ?? []
                guard alive.isAlive else { return }
                songs += page
                more = page.count == 100
                loading = false
                list.set(songs)
            }
        }
        scroller.onNearEnd { loadMore() }
        loadMore()
        return scroller
    }
}

/// Starred albums and songs.
@MainActor
enum FavoritesPage {
    static func make(_ env: Env) -> NavigationPage {
        let app = env.app
        let loader = Loader()
        var songs: [Song] = []
        let shuffle = Button(icon: "media-playlist-shuffle-symbolic", "flat") {
            guard !songs.isEmpty else { return }
            env.play(songs, source: "Favourites", shuffled: true)
        }.tooltip("Shuffle Favourites")
        loader.bin.observe {
            let scope = app.scope.scope
            _ = app.scope.generation
            loader.run({ () -> Starred2? in
                let client = app.client
                app.beginLoadPass()
                return await app.cached(CacheKey.starred(scope.cacheKey)) { try await client.starred(scope: scope) }
            }) { starred in
                songs = starred.songs
                guard !starred.songs.isEmpty || !starred.albums.isEmpty || !starred.artists.isEmpty else {
                    return Loader.empty("No Favourites", icon: "music-heart-symbolic", description: "Starred songs, albums and artists appear here.")
                }
                let body = Box.vertical(spacing: 24)
                if !starred.artists.isEmpty {
                    body.append(Shelf.make("Artists", cards: starred.artists.map { Cards.artist(env, $0, side: 96) }))
                }
                if !starred.albums.isEmpty {
                    body.append(Shelf.make("Albums", cards: starred.albums.map { Cards.album(env, $0) }))
                }
                if !starred.songs.isEmpty {
                    body.append(Label("Songs", "shelf-title"))
                    body.append(SongList.make(env, starred.songs, source: "Favourites"))
                }
                return body.margin(horizontal: 12, vertical: 24)
            }
        }
        return Page.make("Favourites", content: loader.bin) { bar in bar.end(shuffle) }
    }
}

/// The library as the server's folders: artists' directories, then albums, then files.
@MainActor
enum FolderPage {
    static func make(_ env: Env, folder: FolderRef?) -> NavigationPage {
        let app = env.app
        let loader = Loader()
        if let folder {
            loader.run({ try? await app.client.musicDirectory(id: folder.id) }) { directory in
                let body = Box.vertical(spacing: 18)
                if !directory.folders.isEmpty {
                    let list = ListBox()
                    for child in directory.folders {
                        let artwork = ArtworkView(app, size: .thumb, side: 40, shape: .thumb)
                        artwork.show(child.song.coverArt, fallback: child.song.title)
                        let row = Box.horizontal(spacing: 12) {
                            artwork.root
                            Label(child.song.title).ellipsize().hexpand()
                            Icon("go-next-symbolic")
                        }.margin(horizontal: 12, vertical: 6)
                        list.append(row) { env.open(.folder(FolderRef(id: child.id, name: child.song.title))) }
                    }
                    body.append(list)
                }
                if !directory.songs.isEmpty {
                    body.append(SongList.make(env, directory.songs, source: directory.name))
                }
                if directory.folders.isEmpty, directory.songs.isEmpty {
                    return Loader.empty("Empty Folder", icon: "folder-symbolic")
                }
                return body.margin(horizontal: 12, vertical: 24)
            }
        } else {
            loader.run({ try? await app.client.folderIndexes(scope: app.scope.scope) }) { indexes in
                let body = Box.vertical(spacing: 18)
                for index in indexes {
                    let group = PreferencesGroup(index.name)
                    for entry in index.artists {
                        group.add(ActionRow(entry.name, icon: "folder-symbolic") {
                            env.open(.folder(FolderRef(id: entry.id, name: entry.name)))
                        }.chevron())
                    }
                    body.append(group)
                }
                if indexes.isEmpty { return Loader.empty("No Folders", icon: "folder-symbolic") }
                return body.margin(horizontal: 12, vertical: 24)
            }
        }
        return Page.make(folder?.name ?? "Folders", content: loader.bin)
    }
}

/// Every track, two hundred at a time, as Navidrome lists them for an empty search.
@MainActor
enum TracksPage {
    static func make(_ env: Env) -> NavigationPage {
        let app = env.app
        let list = SongList.long(env, source: "Tracks")
        let stack = Stack()
        let scroller = ScrolledWindow(list.view).vexpand()
        stack.add(Spinner().size(32).halign(GTK_ALIGN_CENTER).valign(GTK_ALIGN_CENTER), name: "loading")
        stack.add(scroller, name: "list")
        stack.add(Loader.empty(
            "No Tracks Listed", icon: "view-list-symbolic",
            description: "This server does not list every track at once. Albums and Artists still have them all."
        ), name: "empty")
        var songs: [Song] = []
        var loading = false
        var more = true
        let alive = stack.liveness
        func loadMore() {
            guard !loading, more else { return }
            loading = true
            let offset = songs.count
            Task { @MainActor in
                let page = (try? await app.client.search(query: "", artistCount: 0, albumCount: 0, songCount: 200, songOffset: offset, scope: app.scope.scope))?.songs ?? []
                guard alive.isAlive else { return }
                let known = Set(songs.map(\.id))
                songs += page.filter { !known.contains($0.id) }
                more = page.count == 200
                loading = false
                list.set(songs)
                stack.visibleName = songs.isEmpty ? "empty" : "list"
            }
        }
        scroller.onNearEnd { loadMore() }
        loadMore()
        let shuffle = Button(icon: "media-playlist-shuffle-symbolic", "flat") { app.stations.play(.library) }
        shuffle.tooltip("Shuffle All Tracks")
        return Page.make("Tracks", content: stack, scrolls: false, clamp: nil) { bar in bar.end(shuffle) }
    }
}

/// Plexamp's categories that Navidrome has no list for, cut from the whole album list.
@MainActor
enum LibraryFacetPage {
    static func make(_ env: Env, facet: LibraryFacet) -> NavigationPage {
        let app = env.app
        let index = app.libraryIndex
        let slot = Bin(Spinner().size(32).halign(GTK_ALIGN_CENTER).valign(GTK_ALIGN_CENTER))
        slot.observe {
            let scope = app.scope.scope
            _ = app.scope.generation
            Task { await index.ensureLoaded(scope: scope) }
        }
        slot.observe {
            guard !index.albums.isEmpty || !index.isLoading else { return }
            switch facet {
            case .labels: slot.child = groups(env, index.labels, empty: "No record labels tagged")
            case .moods: slot.child = groups(env, index.moods, empty: "No moods tagged")
            case .compilations: slot.child = AlbumCollection.grid(env, index.compilations)
            case .soundtracks: slot.child = AlbumCollection.grid(env, index.soundtracks)
            case .live: slot.child = AlbumCollection.grid(env, index.live)
            case .singles: slot.child = AlbumCollection.grid(env, index.singles)
            }
        }
        return Page.make(facet.title, content: slot, scrolls: false, clamp: nil)
    }

    private static func groups(_ env: Env, _ groups: [LibraryFacets.Group], empty: String) -> Widget {
        guard !groups.isEmpty else {
            return Loader.empty(empty, icon: "music-tag-symbolic", description: "Your server reads these from the files' tags.")
        }
        let list = ListBox()
        for group in groups {
            let row = ActionRow(group.name) { env.open(.albumCollection(title: group.name, albums: group.albums)) }
            row.suffix(Label("\(group.albums.count)", "song-meta")).chevron()
            list.append(row)
        }
        return ScrolledWindow(Clamp(list.margin(horizontal: 12, vertical: 24), maximum: 900)).vexpand()
    }
}
