import CGtk
import Foundation

/// Plexamp's Show Similar Tracks, in a dialog over the player: Sonically Similar from our
/// sonic analysis, Related from Navidrome's agents, and Outside Your Comfort Zone — close
/// in sound, by other artists, unplayed first. Only the lists that have anything show.
@MainActor
enum SimilarTracks {
    typealias Kind = SimilarKind

    /// The lists that have anything in them, in Plexamp's order: see `similarLists`.
    static func lists(_ env: Env, song: Song, limit: Int = 50) async -> [(Kind, [Song])] {
        await env.app.similarLists(to: song, limit: limit).map { ($0.kind, $0.songs) }
    }

    static func present(_ env: Env, song: Song) {
        let loader = Loader()
        Dialogs.sheet("Similar to \(song.title)", content: loader.bin, width: 560, height: 680)
        loader.run({ () -> [(Kind, [Song])]? in
            await lists(env, song: song)
        }) { lists in
            guard !lists.isEmpty else {
                return StatusPage(icon: "weather-snow-symbolic", title: "This track is a snowflake", description: "There isn't another like it.")
            }
            let stack = Stack()
            let switcher = Box.horizontal().css("linked").halign(GTK_ALIGN_CENTER)
            var first: ToggleButton?
            for (kind, songs) in lists {
                let source = "\(kind.rawValue) · \(song.title)"
                let page = Box.vertical(spacing: 12) {
                    Box.horizontal(spacing: 8) {
                        Button("Play All", icon: "media-playback-start-symbolic", "suggested-action", "pill") {
                            env.play(songs, source: source)
                        }
                        MenuButton(icon: "view-more-symbolic", "flat", "circular") { Menu([Menus.queueItems(env, songs)]) }
                    }
                    SongList.make(env, songs, source: source, showsNavigation: false)
                    Label(kind.footer(song), "caption", "dim").wrap()
                }.margin(12)
                stack.add(ScrolledWindow(Clamp(page, maximum: 600)).vexpand(), name: kind.rawValue)
                let toggle = ToggleButton(kind.short)
                if let first { toggle.group(with: first) } else { toggle.isActive = true }
                first = first ?? toggle
                Signal.connect(toggle.widget, "toggled") { if toggle.isActive { stack.visibleName = kind.rawValue } }
                switcher.append(toggle)
            }
            return Box.vertical(spacing: 8) {
                if lists.count > 1 { switcher.margin(horizontal: 0, vertical: 8) }
                stack
            }
        }
    }
}
