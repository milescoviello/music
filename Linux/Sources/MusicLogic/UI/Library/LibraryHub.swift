import CGtk
import Foundation

/// The Library tab's first page, the phone's `LibraryHubView`: one grouped list of every
/// way into the library (Apple Music's answer to more peers than a tab bar holds), then
/// Plexamp's categories, then the tools, with the albums added most recently beneath.
@MainActor
enum LibraryHub {
    static func make(_ env: Env) -> NavigationPage {
        let app = env.app
        func row(_ title: String, _ symbol: String, _ destination: Destination) -> ActionRow {
            let row = ActionRow(title, icon: Symbol.icon(symbol)) { env.open(destination) }
            row.chevron()
            return row
        }

        let main = PreferencesGroup {
            row("Playlists", "music.note.list", .playlists)
            row("Artists", "music.microphone", .artists)
            row("Albums", "square.stack", .albums(.alphabeticalByName))
            row("Tracks", "music.note", .tracks)
            row("Recently Played", "clock.arrow.circlepath", .albums(.recent))
            row("Most Played", "chart.bar", .albums(.frequent))
            row("Genres", "guitars", .genres)
            row("Stations", "dot.radiowaves.left.and.right", .stations)
            row("Charts", "chart.line.uptrend.xyaxis", .charts)
        }
        // Plexamp's other categories, cut from the whole album list.
        let facets = PreferencesGroup()
        for facet in LibraryFacet.allCases { facets.add(row(facet.title, facet.symbol, .libraryFacet(facet))) }
        facets.add(row("Folders", "folder", .folder(nil)))

        // The one row whose contents live on this computer, so the one where a count says
        // something the page does not.
        let downloads = row("Downloads", "arrow.down.circle", .downloads)
        let count = Label("", "row-value")
        downloads.suffix(count)
        count.observe {
            let total = app.downloads.catalog.entries.count
            count.text = total > 0 ? String(total) : ""
        }
        let tools = PreferencesGroup {
            row("Favourites", "heart", .favorites)
            downloads
            row("Rediscover", "clock.arrow.circlepath", .rediscover)
            row("Make a Playlist", "sparkles", .vibePlaylist)
            row("Lyric Search", "text.magnifyingglass", .lyricSearch(""))
            row("Trip Mode", "airplane", .tripMode)
            row("Stats", "chart.bar.xaxis", .stats)
            row("Library Health", "stethoscope", .libraryHealth)
            row("Duplicate Albums", "square.on.square", .duplicateAlbums)
            row("Request Music", "arrow.down.heart", .requestMusic(""))
            row("Settings", "gearshape", .settings)
        }

        let recent = FlowBox(spacing: 12).columns(min: 2, max: 6).homogeneous()
        let recentGroup = PreferencesGroup("Recently Added")
            .suffix(Button("See All", "flat", "see-all") { env.open(.albums(.newest)) })
        recentGroup.add(recent)
        recentGroup.isVisible = false

        let content = Box.vertical(spacing: 20) {
            main
            facets
            tools
            recentGroup
        }.margins(top: 4, bottom: 24, start: 16, end: 16)

        content.observe {
            let scope = app.scope.scope
            _ = app.scope.generation
            let alive = recent.liveness
            Task { @MainActor in
                let albums = (try? await app.client.albums(type: .newest, size: 6, scope: scope)) ?? []
                guard alive.isAlive else { return }
                recent.removeAll()
                for album in albums { recent.append(Cards.album(env, album, side: 160)) }
                recentGroup.isVisible = !albums.isEmpty
            }
        }
        return Page.make("Library", content: content, clamp: 720) { bar in
            bar.end(ScopeMenu.make(app))
        }
    }
}
