import CGtk
import Foundation

/// The Library section's first page: every way into the library as a list, Plexamp's
/// categories after Navidrome's own, and the most recently added albums beneath.
@MainActor
enum LibraryHub {
    static func make(_ env: Env) -> NavigationPage {
        let app = env.app
        func row(_ title: String, _ icon: String, _ destination: Destination) -> ActionRow {
            let row = ActionRow(title, icon: icon) { env.open(destination) }
            row.chevron()
            return row
        }

        let main = PreferencesGroup {
            row("Playlists", "view-list-symbolic", .playlists)
            row("Artists", "avatar-default-symbolic", .artists)
            row("Albums", "media-optical-symbolic", .albums(.alphabeticalByName))
            row("Tracks", "audio-x-generic-symbolic", .tracks)
            row("Recently Played", "document-open-recent-symbolic", .albums(.recent))
            row("Most Played", "view-continuous-symbolic", .albums(.frequent))
            row("Genres", "applications-multimedia-symbolic", .genres)
            row("Stations", "network-wireless-symbolic", .stations)
            row("Charts", "power-profile-performance-symbolic", .charts)
        }
        let facets = PreferencesGroup()
        for facet in LibraryFacet.allCases { facets.add(row(facet.title, facet.icon, .libraryFacet(facet))) }
        facets.add(row("Folders", "folder-symbolic", .folder(nil)))

        let downloads = row("Downloads", "folder-download-symbolic", .downloads)
        let count = Label("", "dim")
        downloads.suffix(count)
        count.observe {
            let total = app.downloads.catalog.entries.count
            count.text = total > 0 ? String(total) : ""
        }
        let more = PreferencesGroup {
            row("Favourites", "music-heart-symbolic", .favorites)
            downloads
            row("Rediscover", "document-open-recent-symbolic", .rediscover)
            row("Make a Playlist", "starred-symbolic", .vibePlaylist)
            row("Lyric Search", "edit-find-symbolic", .lyricSearch(""))
            row("Trip Mode", "airplane-mode-symbolic", .tripMode)
            row("Stats", "x-office-spreadsheet-symbolic", .stats)
            row("Library Health", "dialog-information-symbolic", .libraryHealth)
            row("Request Music", "list-add-symbolic", .requestMusic(""))
        }

        let recent = FlowBox(spacing: 12).columns(min: 2, max: 6).homogeneous()
        let recentGroup = PreferencesGroup("Recently Added").suffix(Button("See All", "flat") { env.open(.albums(.newest)) })
        recentGroup.add(recent)
        recentGroup.isVisible = false

        let content = Box.vertical(spacing: 24) {
            main
            facets
            more
            recentGroup
        }.margin(horizontal: 12, vertical: 24)

        content.observe {
            let scope = app.scope.scope
            _ = app.scope.generation
            let alive = recent.liveness
            Task { @MainActor in
                let albums = (try? await app.client.albums(type: .newest, size: 12, scope: scope)) ?? []
                guard alive.isAlive else { return }
                recent.removeAll()
                for album in albums { recent.append(Cards.album(env, album)) }
                recentGroup.isVisible = !albums.isEmpty
            }
        }
        return Page.make("Library", content: content) { bar in
            bar.end(ScopeMenu.make(app))
        }
    }
}
