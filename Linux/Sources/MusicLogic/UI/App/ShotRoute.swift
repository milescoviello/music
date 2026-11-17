import CGtk
import Foundation

/// Where a screenshot run (`tools/linux-shot`) opens: `MUSIC_OPEN` names a tab
/// (`home`, `library`, `search`, `downloads`, `settings`), `player`, `search:<words>`,
/// `album:<name>`, `artist:<name>`, `playlist:<name>`, or a page that needs no
/// id (`playlists`, `artists`, `albums`, `genres`, `favorites`, `stats`, `charts`, …).
/// Opened once the app has signed in and built its window.
@MainActor
enum ShotRoute {
    private static let pages: [String: Destination] = [
        "playlists": .playlists, "artists": .artists, "albums": .albums(.recent),
        "genres": .genres, "favorites": .favorites, "stats": .stats, "charts": .charts,
        "tracks": .tracks, "mixes": .dailyMixes, "stations": .stations,
        "rediscover": .rediscover, "trip": .tripMode, "recap": .recap,
        "audio": .audioSettings, "streaming": .streamingSettings,
        "experience": .experienceSettings, "offline": .offlineSettings,
        "diagnostics": .diagnostics,
    ]

    static func open(_ route: String?, app: AppState, shell: Shell, tries: Int = 0) {
        guard let route, !route.isEmpty else { return }
        guard app.phase == .ready, shell.navigation != nil else {
            guard tries < 100 else { return }
            let next = tries + 1
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(200))
                open(route, app: app, shell: shell, tries: next)
            }
            return
        }
        if let colon = route.firstIndex(of: ":"), ["album", "artist", "playlist"].contains(String(route[..<colon])) {
            let kind = String(route[..<colon])
            let name = String(route[route.index(after: colon)...])
            Task { @MainActor in
                if kind == "playlist" {
                    await app.playlistStore.refreshIfStale()
                    guard let playlist = app.playlistStore.playlists.first(where: { $0.name == name }) else { return }
                    app.navigator.open(.playlist(PlaylistRef(playlist)))
                    return
                }
                guard let found = await app.search.search(name, scope: app.scope.scope) else { return }
                if kind == "album", let album = found.results.albums.first {
                    app.navigator.open(.album(AlbumRef(album)))
                } else if kind == "artist", let artist = found.results.artists.first {
                    app.navigator.open(.artist(ArtistRef(artist)))
                }
            }
        } else if route.hasPrefix("search:") {
            shell.select(.search)
            shell.navigation?.searchEntry?.text = String(route.dropFirst(7))
        } else if route.hasPrefix("player:"), let mode = PhonePlayer.Mode(rawValue: String(route.dropFirst(7))) {
            shell.player?.open(mode)
        } else if route == "player" {
            app.navigator.showsPlayer = true
        } else if let section = Shell.Section(rawValue: route) {
            shell.select(section)
        } else if let page = pages[route] {
            app.navigator.open(page)
        }
    }
}
