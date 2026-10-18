import CGtk
import Foundation
import Observation

/// Home: Plexamp's shelves, in the order and with the ones chosen in Edit Home — Made for
/// You, Recent Plays, Stations, the album shelves, favourites, forgotten favourites, On
/// This Day — all from the phone's `HomeModel`.
@MainActor
enum HomePage {
    private static let layoutKey = "home.layout"

    static func make(_ env: Env) -> NavigationPage {
        let app = env.app
        let model = HomeModel()
        let shelves = Box.vertical(spacing: 28)
        let body = Box.vertical(spacing: 0) { shelves }.margin(horizontal: 12, vertical: 18)
        body.keep(model)

        let layoutVersion = LayoutVersion()
        body.keep(layoutVersion)
        body.observe {
            _ = layoutVersion.value
            _ = model.hasLoaded
            _ = model.recentlyPlayed
            _ = model.mostPlayedThisMonth
            _ = model.onThisDay
            _ = model.moreInGenre?.name
            _ = model.notPlayedLately
            _ = app.mixes.mixes
            _ = app.mixes.isBuilding
            _ = app.recentPlays.recent.origins
            rebuild(env, model: model, into: shelves)
        }
        body.observe {
            let scope = app.scope.scope
            _ = app.scope.generation
            Task { await model.load(appState: app, scope: scope) }
        }
        app.mixes.load(appState: app, scope: MixScope.current(app))

        let page = Page.make("Home", content: body) { bar in
            bar.end(MenuButton(icon: "emblem-system-symbolic", "flat") {
                Menu([[
                    .action("Edit Home…") { editLayout { layoutVersion.value += 1 } },
                    .action("Refresh") { Task { await model.load(appState: app, scope: app.scope.scope) } },
                    .action("Settings") { env.navigation.shell?.select(.settings) },
                ]])
            })
            bar.end(ScopeMenu.make(app))
            bar.end(Button(icon: "media-playlist-shuffle-symbolic", "flat") { app.stations.play(.library) }.tooltip("Shuffle Library"))
        }
        return page
    }

    /// Bumped when the layout is edited, so the shelves are rebuilt.
    @Observable
    final class LayoutVersion {
        var value = 0
    }

    private static var layout: HomeLayout {
        HomeLayout.restored(from: UserDefaults.standard.data(forKey: layoutKey))
    }

    private static func rebuild(_ env: Env, model: HomeModel, into shelves: Box) {
        shelves.removeAll()
        if model.isEmpty, model.hasLoaded, env.app.mixes.mixes.isEmpty {
            shelves.append(StatusPage(
                icon: "go-home-symbolic", title: "Nothing to Show",
                description: "Couldn't reach the server, or the library is empty.",
                child: Button("Try Again", "pill") {
                    Task { await model.load(appState: env.app, scope: env.app.scope.scope) }
                }.halign(GTK_ALIGN_CENTER)
            ))
            return
        }
        for hub in layout.visible {
            if let shelf = shelf(env, hub, model: model) { shelves.append(shelf) }
        }
    }

    private static func shelf(_ env: Env, _ hub: HomeHub, model: HomeModel) -> Widget? {
        let app = env.app
        switch hub {
        case .madeForYou:
            return MixPages.shelf(env)
        case .recentPlays:
            let origins = app.recentPlays.recent.origins
            guard !origins.isEmpty else { return nil }
            return Shelf.make("Recent Plays", cards: origins.map { origin in recentPlay(env, origin) })
        case .stations:
            return MixPages.stationsShelf(env)
        case .recentlyPlayed:
            return albums(env, "Recently Played", model.recentlyPlayed, more: .albums(.recent))
        case .recentlyAdded:
            return albums(env, "Recently Added", model.recentlyAdded, more: .albums(.newest))
        case .mostPlayed:
            return albums(env, "Most Played", model.mostPlayed, more: .albums(.frequent))
        case .mostPlayedThisMonth:
            return albums(env, model.monthTitle, model.mostPlayedThisMonth, more: .charts)
        case .moreInGenre:
            guard let genre = model.moreInGenre else { return nil }
            return albums(env, "More in \(genre.name)", genre.albums, more: .genre(genre.name))
        case .bestOfLastYear:
            return albums(env, "Best of \(model.lastYear)", model.bestOfLastYear,
                          more: .albumCollection(title: "Best of \(model.lastYear)", albums: model.bestOfLastYear))
        case .notPlayedLately:
            return albums(env, "Haven't Played Lately", model.notPlayedLately,
                          more: .albumCollection(title: "Haven't Played Lately", albums: model.notPlayedLately))
        case .favourites:
            guard !model.favoriteSongs.isEmpty else { return nil }
            return Box.vertical(spacing: 8) {
                header("Favourites") { env.open(.favorites) }
                SongList.make(env, model.favoriteSongs, source: "Favourites")
            }
        case .forgottenFavourites:
            let forgotten = model.forgotten
            guard !forgotten.songs.isEmpty else { return nil }
            return Box.vertical(spacing: 8) {
                header("Forgotten Favourites") { env.open(.rediscover) }
                SongList.make(env, forgotten.songs, source: "Forgotten Favourites") { song in
                    Rediscovery.lastPlayedText(forgotten.lastPlayed[song.id])
                }
            }
        case .onThisDay:
            guard !model.onThisDay.isEmpty else { return nil }
            return Shelf.make("On This Day", cards: model.onThisDay.map { entry in
                let card = Box.vertical(spacing: 2) {
                    Cards.album(env, entry.album)
                    Label(entry.years == 1 ? "1 year ago today" : "\(entry.years) years ago today", "caption", "accent").margin(horizontal: 6, vertical: 0)
                }
                return card
            })
        }
    }

    private static func header(_ title: String, more: @escaping @MainActor () -> Void) -> Widget {
        Box.horizontal {
            Label(title, "shelf-title").hexpand()
            Button("See All", "flat", action: more)
        }
    }

    private static func albums(_ env: Env, _ title: String, _ albums: [Album], more: Destination) -> Widget? {
        guard !albums.isEmpty else { return nil }
        return Shelf.make(title, more: { env.open(more) }, cards: albums.map { Cards.album(env, $0) })
    }

    private static func recentPlay(_ env: Env, _ origin: PlayOrigin) -> Widget {
        let card = AlbumCardView(env, side: 136)
        card.bind(title: origin.title, subtitle: origin.subtitle, cover: origin.coverArt)
        return Button(child: card.root, "card-button", "flat") {
            switch origin {
            case let .album(id, name, artist, cover):
                env.open(.album(AlbumRef(id: id, name: name, artist: artist, coverArt: cover)))
            case let .playlist(id, name, cover):
                env.open(.playlist(PlaylistRef(id: id, name: name, coverArt: cover)))
            case let .artist(id, name, cover):
                env.open(.artist(ArtistRef(id: id, name: name, coverArt: cover)))
            case let .station(station, _):
                env.app.stations.play(station)
            }
        }
    }

    /// Plexamp's home editor: show or hide each shelf, move it, reset.
    private static func editLayout(_ changed: @escaping @MainActor () -> Void) {
        var layout = self.layout
        let list = ListBox()
        func fill() {
            list.removeAll()
            for (index, hub) in layout.order.enumerated() {
                let row = SwitchRow(hub.title, isOn: layout.isVisible(hub)) { on in
                    layout.setVisible(on, hub)
                }
                let up = Button(icon: "go-up-symbolic", "flat", "circular") {
                    layout.move(fromOffsets: IndexSet(integer: index), toOffset: index - 1)
                    fill()
                }
                let down = Button(icon: "go-down-symbolic", "flat", "circular") {
                    layout.move(fromOffsets: IndexSet(integer: index), toOffset: index + 2)
                    fill()
                }
                up.isSensitive = index > 0
                down.isSensitive = index + 1 < layout.order.count
                adw_action_row_add_prefix(row.widget.cast(), up.valign(GTK_ALIGN_CENTER).widget)
                adw_action_row_add_prefix(row.widget.cast(), down.valign(GTK_ALIGN_CENTER).widget)
                list.append(row)
            }
        }
        fill()
        let body = Box.vertical(spacing: 12) {
            list
            Label("Shelves with nothing to show stay out of the way on their own.", "caption", "dim").wrap()
            Box.horizontal(spacing: 8) {
                Button("Reset to Default", "pill") {
                    layout = .default
                    fill()
                }
                Spacer()
            }
        }.margin(12)
        let dialog = Dialogs.sheet("Edit Home", content: ScrolledWindow(Clamp(body, maximum: 520)).vexpand(), width: 460, height: 640)
        Signal.connect(dialog, "closed") {
            UserDefaults.standard.set(layout.encoded, forKey: layoutKey)
            changed()
        }
    }
}
