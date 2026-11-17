import CGtk
import Foundation

/// Where a screenshot run (`tools/linux-shot`) opens: `MUSIC_OPEN` names a tab
/// (`home`, `library`, `search`, `downloads`, `settings`), `player`, `search:<words>`, or a
/// page that needs no
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
        if route.hasPrefix("search:") {
            shell.select(.search)
            shell.navigation?.searchEntry?.text = String(route.dropFirst(7))
        } else if route == "player" {
            app.navigator.showsPlayer = true
        } else if let section = Shell.Section(rawValue: route) {
            shell.select(section)
        } else if let page = pages[route] {
            app.navigator.open(page)
        }
    }
}
