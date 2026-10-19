import CGtk
import Foundation

/// Which library the daily mixes come from, on a server with more than one: the phone's
/// "mixes.folderID", -1 for all of them.
@MainActor
enum MixScope {
    static let key = "mixes.folderID"

    static func current(_ app: AppState) -> LibraryScope {
        let id = UserDefaults.standard.object(forKey: key) as? Int ?? -1
        guard id != -1, let folder = app.scope.folders.first(where: { $0.id == id }) else { return .all }
        return .folder(id: folder.id, name: folder.name)
    }

    static func menuItem(_ app: AppState) -> Menu.Item? {
        guard app.scope.isSwitchable else { return nil }
        let id = UserDefaults.standard.object(forKey: key) as? Int ?? -1
        return .choice(
            "Mixes From",
            options: [("-1", "Both Libraries")] + app.scope.folders.map { (String($0.id), $0.name) },
            selected: String(id)
        ) { chosen in
            UserDefaults.standard.set(Int(chosen) ?? -1, forKey: key)
            app.mixes.load(appState: app, scope: current(app))
        }
    }
}

/// Daily mixes and stations: Made for You's tiles, a mix's own page, every station.
@MainActor
enum MixPages {
    // MARK: - Made for You

    static func shelf(_ env: Env) -> Widget? {
        let mixes = env.app.mixes
        if mixes.mixes.isEmpty {
            guard mixes.isBuilding else { return nil }
            return Box.vertical(spacing: 8) {
                Label("Made for You", "shelf-title")
                Box.horizontal(spacing: 8) {
                    Spinner().size(16)
                    Label("Building today's mixes…", "caption", "dim")
                }
            }
        }
        var cards = mixes.mixes.map { card(env, $0) }
        if mixes.canLoadMore {
            let more = Spinner().size(24).valign(GTK_ALIGN_CENTER).margin(24)
            more.onMap { mixes.loadMore(appState: env.app, scope: MixScope.current(env.app)) }
            cards.append(more)
        }
        return Shelf.make("Made for You", more: { env.open(.dailyMixes) }, cards: cards)
    }

    private static func card(_ env: Env, _ mix: DailyMixes.Mix) -> Widget {
        let box = Box.vertical(spacing: 6) {
            tile(env.app, covers: mix.covers, side: AlbumCardView.side)
            Label(mix.title, "card-title").ellipsize().maxWidthChars(1)
            Label(mix.subtitle, "card-subtitle").ellipsize().maxWidthChars(1)
        }.size(width: AlbumCardView.side)
        return Button(child: box, "card-button", "flat") { env.open(.dailyMix(mix.id)) }
    }

    /// Four covers in a square, or one when a mix has fewer albums than that.
    static func tile(_ app: AppState, covers: [String], side: Int32) -> Widget {
        guard covers.count >= 4 else {
            let artwork = ArtworkView(app, size: .card, side: side, shape: .card)
            artwork.show(covers.first)
            return artwork.root
        }
        let grid = Grid(rowSpacing: 0, columnSpacing: 0)
        for (index, cover) in covers.prefix(4).enumerated() {
            let artwork = ArtworkView(app, size: side > 100 ? .card : .thumb, side: side / 2, shape: .card)
            artwork.root.css("flat-corners")
            artwork.show(cover)
            grid.attach(artwork.root, column: Int32(index % 2), row: Int32(index / 2))
        }
        return Bin(grid).css("artwork").clipped().size(width: side, height: side).halign(GTK_ALIGN_CENTER)
    }

    static func list(_ env: Env) -> NavigationPage {
        let app = env.app
        let list = ListBox()
        let body = Box.vertical(spacing: 12) { list }.margin(horizontal: 12, vertical: 24)
        list.observe {
            let mixes = app.mixes
            list.removeAll()
            for mix in mixes.mixes {
                let row = Box.horizontal(spacing: 12) {
                    tile(app, covers: mix.covers, side: 56)
                    Box.vertical(spacing: 2) {
                        Label(mix.title).ellipsize()
                        Label("\(mix.songs.count) songs · \(mix.subtitle)", "caption", "dim").ellipsize()
                    }.valign(GTK_ALIGN_CENTER).hexpand()
                }.margin(horizontal: 12, vertical: 6)
                list.append(row) { env.open(.dailyMix(mix.id)) }
            }
            if mixes.canLoadMore {
                let more = Box.horizontal(spacing: 8) {
                    Spinner().size(16)
                    Label("Building more…", "caption", "dim")
                }.margin(12)
                more.onMap { mixes.loadMore(appState: app, scope: MixScope.current(app)) }
                list.append(more)
            }
            if mixes.mixes.isEmpty, !mixes.isBuilding {
                list.placeholder(StatusPage(icon: "starred-symbolic", title: "No Mixes Yet", description: "Play a few things and these build themselves.").compact())
            }
        }
        app.mixes.load(appState: app, scope: MixScope.current(app))
        return Page.make("Made for You", content: body) { bar in
            if let item = MixScope.menuItem(app) {
                bar.end(MenuButton(icon: "folder-open-symbolic", "flat") { Menu([[item]]) })
            }
        }
    }

    /// One mix: it keeps growing as you scroll to its end, the way the phone's does.
    static func mix(_ env: Env, id: String) -> NavigationPage {
        let app = env.app
        let slot = Bin()
        slot.observe {
            guard let mix = app.mixes.mix(id: id) else {
                slot.child = StatusPage(icon: "starred-symbolic", title: "Mix Not Available", description: "This mix has been replaced by today's.")
                return
            }
            let header = Box.horizontal(spacing: 24) {
                tile(app, covers: mix.covers, side: 200)
                Box.vertical(spacing: 6) {
                    Label(mix.title, "page-title").wrap()
                    Label("\(mix.songs.count) songs · \(mix.subtitle)", "dim").wrap()
                    Box.horizontal(spacing: 8) {
                        Button("Play", icon: "media-playback-start-symbolic", "suggested-action", "pill") { env.play(mix.songs, source: mix.title) }
                        Button("Shuffle", icon: "media-playlist-shuffle-symbolic", "pill") { env.play(mix.songs, source: mix.title, shuffled: true) }
                        Button("Download", icon: "folder-download-symbolic", "pill") {
                            app.downloads.download(mix.songs, groupID: "mix-\(mix.id)", groupName: mix.title)
                        }
                    }.margins(top: 12)
                }.valign(GTK_ALIGN_END).hexpand()
            }
            let body = Box.vertical(spacing: 18) {
                header
                SongList.make(env, mix.songs, source: mix.title)
            }
            if mix.isExhausted != true {
                let more = Box.horizontal(spacing: 8) {
                    Spinner().size(16)
                    Label("Adding more…", "caption", "dim")
                }
                more.onMap { app.mixes.extend(mixID: id, appState: app, scope: MixScope.current(app)) }
                body.append(more)
            }
            slot.child = body.margin(horizontal: 12, vertical: 24)
        }
        return Page.make(app.mixes.mix(id: id)?.title ?? "Mix", content: slot)
    }

    // MARK: - Stations

    static let core: [Station] = [.library, .deepCuts, .timeTravel, .randomAlbum]

    static func stationsShelf(_ env: Env) -> Widget {
        let app = env.app
        var cards: [Widget] = core.map { station in
            stationCard(title: station.title, subtitle: station.subtitle, symbol: station.symbol) { app.stations.play(station) }
        }
        cards.append(stationCard(title: "Artist Mix Builder", subtitle: "Pick a few artists", symbol: Station.artistMix(ids: [], names: []).symbol) {
            env.open(.mixBuilder(.artists))
        })
        cards.append(stationCard(title: "Album Mix Builder", subtitle: "Pick a few albums", symbol: Station.albumMix(ids: [], names: []).symbol) {
            env.open(.mixBuilder(.albums))
        })
        return Shelf.make("Stations", more: { env.open(.stations) }, cards: cards)
    }

    private static func stationCard(title: String, subtitle: String, symbol: String, action: @escaping @MainActor () -> Void) -> Widget {
        let side: Int32 = 120
        let art = DrawingArea(width: side, height: side) { cairo, width, height in
            cairo.save()
            cairo.roundedRectangle(0, 0, width, height, radius: 8)
            cairo.clip()
            let pattern = cairo_pattern_create_linear(0, 0, width, height)
            cairo_pattern_add_color_stop_rgba(pattern, 0, Style.tint.red, Style.tint.green, Style.tint.blue, 0.55)
            cairo_pattern_add_color_stop_rgba(pattern, 1, Style.tint.red, Style.tint.green, Style.tint.blue, 0.15)
            cairo_set_source(cairo.context, pattern)
            cairo_pattern_destroy(pattern)
            cairo.paint()
            cairo.restore()
        }
        let icon = Icon(Icons.named(symbol), size: 36).halign(GTK_ALIGN_CENTER).valign(GTK_ALIGN_CENTER)
        let box = Box.vertical(spacing: 6) {
            Overlay(art).add(icon)
            Label(title, "card-title").ellipsize().maxWidthChars(1)
            Label(subtitle, "card-subtitle").lines(2).maxWidthChars(1)
        }.size(width: side)
        return Button(child: box, "card-button", "flat", action: action)
    }

    static func stations(_ env: Env) -> NavigationPage {
        let app = env.app
        func row(_ station: Station) -> Widget {
            let row = ActionRow(station.title, subtitle: station.subtitle, icon: Icons.named(station.symbol)) { app.stations.play(station) }
            let spinner = Spinner().size(16).visible(false)
            row.suffix(spinner)
            spinner.observe { spinner.isVisible = app.stations.starting == station }
            return row
        }
        let body = Box.vertical(spacing: 24)
        body.append(PreferencesGroup("Stations") { core.map(row) })
        body.append(PreferencesGroup("Mix Builders") {
            ActionRow("Artist Mix Builder", icon: Icons.named(Station.artistMix(ids: [], names: []).symbol)) { env.open(.mixBuilder(.artists)) }.chevron()
            ActionRow("Album Mix Builder", icon: Icons.named(Station.albumMix(ids: [], names: []).symbol)) { env.open(.mixBuilder(.albums)) }.chevron()
        })
        let moods = PreferencesGroup("Moods")
        for tag in Station.moodTags { moods.add(row(.mood(tag))) }
        body.append(moods)
        moods.observe { moods.isVisible = app.sonic.isAvailable }
        let decades = PreferencesGroup("Decades")
        let genres = PreferencesGroup("Genres")
        decades.isVisible = false
        genres.isVisible = false
        body.append(decades)
        body.append(genres)

        let alive = body.liveness
        Task { @MainActor in
            let client = app.client
            let scope = app.scope.scope
            let thisYear = Calendar.current.component(.year, from: .now)
            let candidates = Array(stride(from: AutoplayRules.decadeStart(of: thisYear), through: 1920, by: -10))
            var found: Set<Int> = []
            await withTaskGroup(of: (Int, Bool).self) { group in
                for start in candidates {
                    group.addTask {
                        let albums = (try? await client.albums(fromYear: start, toYear: start + 9, size: 1, scope: scope)) ?? []
                        return (start, !albums.isEmpty)
                    }
                }
                for await (start, present) in group where present { found.insert(start) }
            }
            let all = (try? await client.genres(scope: scope)) ?? []
            guard alive.isAlive else { return }
            for start in candidates where found.contains(start) { decades.add(row(.decade(start))) }
            decades.isVisible = !found.isEmpty
            for genre in all.sorted(by: { ($0.songCount ?? 0) > ($1.songCount ?? 0) }).prefix(16) {
                genres.add(row(.genre(genre.value)))
            }
            genres.isVisible = !all.isEmpty
        }
        return Page.make("Stations", content: body.margin(horizontal: 12, vertical: 24))
    }
}
