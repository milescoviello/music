import CGtk
import Foundation

/// Every artist, A to Z, with a filter field: the phone's alphabet rail becomes typing,
/// which is how a desktop jumps through a long list.
@MainActor
enum ArtistList {
    static func make(_ env: Env) -> NavigationPage {
        let app = env.app
        let filter = SearchEntry(placeholder: "Filter artists")
        var all: [Artist] = []
        let list = ItemList<Artist, ArtistRowCell>(.list, setup: {
            let cell = ArtistRowCell(app)
            return (cell.root, cell)
        }, bind: { cell, artist, _ in
            cell.bind(artist)
        }, activate: { artist, _ in
            env.open(.artist(ArtistRef(artist)))
        })
        let stack = Stack()
        stack.add(Spinner().size(32).halign(GTK_ALIGN_CENTER).valign(GTK_ALIGN_CENTER), name: "loading")
        stack.add(ScrolledWindow(list.view).vexpand(), name: "list")
        let empty = Bin()
        stack.add(empty, name: "empty")

        func apply() {
            let text = filter.text.trimmingCharacters(in: .whitespaces)
            let shown = text.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(text) }
            list.set(shown)
            if shown.isEmpty {
                empty.child = Loader.empty(all.isEmpty ? "No Artists" : "No Matches", icon: "avatar-default-symbolic")
                stack.visibleName = "empty"
            } else {
                stack.visibleName = "list"
            }
        }
        filter.onSearch { _ in apply() }

        let body = Box.vertical(spacing: 0) {
            Clamp(filter.margin(12), maximum: 600)
            stack.vexpand()
        }
        let alive = body.liveness
        body.observe {
            let scope = app.scope.scope
            _ = app.scope.generation
            stack.visibleName = "loading"
            Task { @MainActor in
                let client = app.client
                app.beginLoadPass()
                let indexes = await app.cached(CacheKey.artistIndex(scope.cacheKey)) {
                    try await client.artists(scope: scope)
                } ?? []
                guard alive.isAlive else { return }
                all = indexes.flatMap(\.artists)
                apply()
            }
        }
        return Page.make("Artists", content: body, scrolls: false, clamp: nil) { bar in
            bar.end(ScopeMenu.make(app))
        }
    }
}

/// An artist as a row: round picture, name, album count.
@MainActor
final class ArtistRowCell {
    let root: Box
    private let artwork: ArtworkView
    private let name = Label("").ellipsize()
    private let count = Label("", "song-meta")

    init(_ app: AppState) {
        let artwork = ArtworkView(app, size: .thumb, side: 40, shape: .round)
        self.artwork = artwork
        let (name, count) = (self.name, self.count)
        root = Box.horizontal(spacing: 12) {
            artwork.root
            name.hexpand()
            count
        }
        root.margin(horizontal: 12, vertical: 4)
        root.keep(self)
    }

    func bind(_ artist: Artist) {
        name.text = artist.name
        count.text = artist.albumCount.map(String.init) ?? ""
        artwork.show(artist.coverArt, fallback: artist.name)
    }
}

/// An artist: Play and Shuffle over the most popular songs, then the discography split
/// Plexamp's way — Albums, Singles & EPs, Live, Compilations — what they appear on, who
/// sounds like them, and what the server knows about them.
@MainActor
enum ArtistPage {
    private static let popularStep = 5

    static func make(_ env: Env, artist: ArtistRef) -> NavigationPage {
        let app = env.app
        let favourite = Button(icon: "emblem-favorite-symbolic", "flat")
        let radio = Button(icon: "network-wireless-symbolic", "flat") {
            Task {
                let mix = await app.radio.artistMix(artist, scope: app.scope.scope)
                app.startRadio(named: "\(artist.name) Radio", songs: mix, station: .artistMix(ids: [artist.id], names: [artist.name]))
            }
        }
        radio.tooltip("Start Artist Radio")

        let body = Box.vertical(spacing: 28)
        let artwork = ArtworkView(app, size: .card, side: 140, shape: .round)
        artwork.show(artist.coverArt, fallback: artist.name)
        let albumCount = Label("", "dim")
        let play = Button("Play", icon: "media-playback-start-symbolic", "suggested-action", "pill")
        let shuffle = Button("Shuffle", icon: "media-playlist-shuffle-symbolic", "pill")
        play.isSensitive = false
        shuffle.isSensitive = false
        body.append(Box.horizontal(spacing: 24) {
            artwork.root
            Box.vertical(spacing: 6) {
                Label(artist.name, "page-title").wrap()
                albumCount
                Box.horizontal(spacing: 8) {
                    play
                    shuffle
                }.margins(top: 12)
            }.valign(GTK_ALIGN_CENTER).hexpand()
        })
        body.append(HermesNoteView.make(env, subject: .artist(id: artist.id, name: artist.name), compact: true))

        let popularBox = Box.vertical(spacing: 8)
        let shelves = Box.vertical(spacing: 28)
        body.append(popularBox)
        body.append(shelves)

        let alive = body.liveness
        Task { @MainActor in
            let client = app.client
            let detail = try? await client.artistDetail(id: artist.id)
            guard alive.isAlive else { return }
            if let detail {
                albumCount.text = detail.albumCount.map { "\($0) albums" } ?? ""
                if let cover = detail.coverArt { artwork.show(cover, fallback: artist.name) }
                let starredOnServer = detail.starred != nil
                favourite.observe {
                    let starred = app.userState.isStarred(id: artist.id, serverValue: starredOnServer)
                    favourite.setCSS("accent", starred)
                    favourite.tooltip(starred ? "Remove Favourite" : "Favourite")
                }
                favourite.onClicked {
                    let starred = app.userState.isStarred(id: artist.id, serverValue: starredOnServer)
                    app.userState.toggleStar(id: artist.id, kind: .artist, currentlyStarred: starred)
                }
                for group in LibraryFacets.byReleaseKind(detail.album ?? []) {
                    shelves.append(albumShelf(env, "\(group.kind.title)", artist: artist.name, group.albums))
                }
            }

            // The chart and the catalogue at once: the chart is one request, the catalogue
            // one per album and cached, so a second visit is instant and works offline.
            let id = artist.id
            async let chart = try? client.topSongs(artist: artist.name, count: 50)
            async let catalogue: [Song]? = app.cached(CacheKey.artistSongs(id)) { try await client.artistSongs(id: id) }
            let popular = ordered(chart: await chart ?? [], catalogue: await catalogue ?? [])
            guard alive.isAlive else { return }
            if !popular.isEmpty {
                play.isSensitive = true
                shuffle.isSensitive = true
                play.onClicked { env.play(popular, source: artist.name) }
                shuffle.onClicked { env.play(popular, source: artist.name, shuffled: true) }
                showPopular(env, popular, artist: artist, in: popularBox, visible: popularStep)
            }

            async let about = try? client.artistInfo(id: id, similarCount: 15)
            async let found = try? client.search(query: artist.name, artistCount: 0, albumCount: 0, songCount: 200)
            let info = await about
            let sonic = await app.sonic.similarArtists(to: id) ?? []
            let own = Set((detail?.album ?? []).map(\.id))
            let appearsOn = LibraryFacets.appearsOn(await found?.songs ?? [], artistID: id, excluding: own)
            guard alive.isAlive else { return }
            if !appearsOn.isEmpty { shelves.append(albumShelf(env, "Appears On", artist: artist.name, appearsOn)) }
            if !sonic.isEmpty {
                shelves.append(Shelf.make("Sonically Similar", cards: sonic.map { Cards.artist(env, $0, side: 96) }))
            }
            let similar = (info?.similarArtists ?? []).filter { !$0.id.isEmpty }
            if !similar.isEmpty {
                shelves.append(Shelf.make("Similar Artists", cards: similar.map { Cards.artist(env, $0, side: 96) }))
            }
            if let biography = info?.plainBiography {
                shelves.append(PreferencesGroup("About") { Label(biography, "dim").wrap().selectable().margin(12) })
            }
        }

        return Page.make(artist.name, content: body.margin(horizontal: 12, vertical: 24)) { bar in
            bar.end(radio)
            bar.end(favourite)
        }
    }

    /// Popular songs, five at a time; a row plays the whole list from there.
    private static func showPopular(_ env: Env, _ songs: [Song], artist: ArtistRef, in box: Box, visible: Int) {
        box.removeAll()
        box.append(Label("Popular", "shelf-title"))
        let list = ListBox()
        for (index, song) in songs.prefix(visible).enumerated() {
            let row = SongRowView(env, style: .artwork, showsNavigation: false)
            row.bind(song)
            list.append(row.root) { env.play(songs, from: index, source: artist.name) }
        }
        box.append(list)
        if songs.count > popularStep {
            let hidden = songs.count - visible
            let title = hidden <= 0 ? "Show Less" : "Show \(min(popularStep, hidden)) More"
            box.append(Button(title, "flat") {
                showPopular(env, songs, artist: artist, in: box, visible: hidden <= 0 ? popularStep : visible + popularStep)
            }.halign(GTK_ALIGN_START))
        }
    }

    private static func albumShelf(_ env: Env, _ title: String, artist: String, _ albums: [Album]) -> Widget {
        var more: (@MainActor () -> Void)?
        if albums.count > 2 {
            more = { env.open(.albumCollection(title: "\(artist) · \(title)", albums: albums)) }
        }
        return Shelf.make(title, more: more, cards: albums.map { Cards.album(env, $0) })
    }

    /// The chart first, then the rest of the catalogue by play count: what Plexamp's
    /// popular list falls back to where Last.fm's chart runs out.
    static func ordered(chart: [Song], catalogue: [Song]) -> [Song] {
        var seen: Set<String> = []
        var result: [Song] = []
        for song in chart where seen.insert(song.id).inserted { result.append(song) }
        let rest = catalogue.enumerated()
            .filter { !seen.contains($0.element.id) }
            .sorted { left, right in
                let a = left.element.playCount ?? 0
                let b = right.element.playCount ?? 0
                return a == b ? left.offset < right.offset : a > b
            }
            .map(\.element)
        return result + rest
    }
}
