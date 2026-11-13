import CGtk
import Foundation

/// Home's two grids of glass tiles: Jump Back In at the top, what was played lately, and
/// the stations, each a small tile rather than a card.
@MainActor
enum HomeTiles {
    /// Up to eight of the recent plays, two rows of four: a click opens it, the play button
    /// that shows on hover plays it.
    static func jumpBackIn(_ env: Env, _ origins: [PlayOrigin]) -> Widget? {
        let shown = Array(origins.prefix(8))
        guard !shown.isEmpty else { return nil }
        let grid = TileGrid(shown.map { tile(env, $0) }, tileWidth: 230, maxColumns: 4)
        return Box.vertical(spacing: 10) {
            Label("Jump Back In", "shelf-title").xalign(0)
            grid.root
        }
    }

    static func stations(_ env: Env) -> Widget {
        let app = env.app
        var tiles: [Widget] = MixPages.core.map { station in
            stationTile(app, title: station.title, subtitle: station.subtitle, symbol: station.symbol, station: station) {
                app.stations.play(station)
            }
        }
        tiles.append(stationTile(app, title: "Artist Mix Builder", subtitle: "Pick a few artists",
                                 symbol: Station.artistMix(ids: [], names: []).symbol) { env.open(.mixBuilder(.artists)) })
        tiles.append(stationTile(app, title: "Album Mix Builder", subtitle: "Pick a few albums",
                                 symbol: Station.albumMix(ids: [], names: []).symbol) { env.open(.mixBuilder(.albums)) })
        let grid = TileGrid(tiles, tileWidth: 260, maxColumns: 3).root
        return Box.vertical(spacing: 10) {
            Box.horizontal(spacing: 8) {
                Label("Stations", "shelf-title").hexpand().xalign(0)
                Button("See All", "flat", "see-all") { env.open(.stations) }
            }
            grid
        }
    }

    private static func tile(_ env: Env, _ origin: PlayOrigin) -> Widget {
        let app = env.app
        let artwork = ArtworkView(app, size: .thumb, side: 56, shape: .thumb)
        let title = Label(origin.title, "tile-title").xalign(0).ellipsize().maxWidthChars(1).hexpand()
        let subtitle = Label(origin.subtitle, "tile-subtitle").xalign(0).ellipsize().maxWidthChars(1)
        switch origin {
        case let .playlist(id, name, cover):
            artwork.show(cover, playlistID: id, fallback: name)
        default:
            artwork.show(origin.coverArt, fallback: origin.title)
        }
        let content = Box.horizontal(spacing: 12) {
            artwork.root
            Box.vertical(spacing: 1) {
                title
                subtitle
            }.valign(GTK_ALIGN_CENTER).hexpand()
        }.margins(top: 0, bottom: 0, start: 0, end: 44)
        let open = Button(child: content, "glass", "jump-tile") { HomeTiles.open(env, origin) }
        let play = Button(icon: "media-playback-start-symbolic", "circular", "tile-play") { HomeTiles.play(env, origin) }
        play.tooltip("Play").halign(GTK_ALIGN_END).valign(GTK_ALIGN_CENTER).margins(top: 0, bottom: 0, start: 0, end: 10)
        play.opacity(0)
        let tile = Overlay(open).add(play)
        tile.onHover { inside in play.opacity(inside ? 1 : 0) }
        return tile
    }

    private static func stationTile(
        _ app: AppState, title: String, subtitle: String, symbol: String, station: Station? = nil,
        action: @escaping @MainActor () -> Void
    ) -> Widget {
        let spinner = Spinner().size(16).visible(false)
        let content = Box.horizontal(spacing: 12) {
            Icon(Icons.named(symbol), size: 20).css("station-icon").valign(GTK_ALIGN_CENTER)
            Box.vertical(spacing: 1) {
                Label(title, "tile-title").xalign(0).ellipsize().maxWidthChars(1)
                Label(subtitle, "tile-subtitle").xalign(0).ellipsize().maxWidthChars(1)
            }.valign(GTK_ALIGN_CENTER).hexpand()
            spinner
        }
        if let station {
            spinner.observe { spinner.isVisible = app.stations.starting == station }
        }
        return Button(child: content, "glass", "station-tile", action: action)
    }

    private static func open(_ env: Env, _ origin: PlayOrigin) {
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

    private static func play(_ env: Env, _ origin: PlayOrigin) {
        let app = env.app
        switch origin {
        case let .album(id, name, _, _):
            Task {
                guard let detail = try? await app.client.albumDetail(id: id), !detail.songs.isEmpty else { return }
                env.play(detail.songs, source: name)
            }
        case let .playlist(id, name, _):
            Task {
                guard let detail = try? await app.client.playlistDetail(id: id), !detail.songs.isEmpty else { return }
                env.play(detail.songs, source: name)
            }
        case let .artist(id, name, _):
            app.stations.play(.artistMix(ids: [id], names: [name]))
        case let .station(station, _):
            app.stations.play(station)
        }
    }
}
