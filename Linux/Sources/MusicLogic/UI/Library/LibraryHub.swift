import CGtk
import Foundation

/// The Library section's first page: tabs across the header bar for Playlists, Artists,
/// Albums, Tracks and Genres, each list right there with its own sorting and filters,
/// and More for every other way in — Plexamp's categories, the folders, the tools — with
/// the most recently added albums beneath.
///
/// Each tab is its own whole page, kept, so it is found scrolled where it was left;
/// switching tabs is not a step in the history. The tab last chosen is remembered.
@MainActor
enum LibraryHub {
    private static let tabKey = "library.tab"

    static func make(_ env: Env) -> NavigationPage {
        let tabs: [(name: String, title: String, page: @MainActor () -> NavigationPage)] = [
            ("playlists", "Playlists", { PlaylistList.make(env) }),
            ("artists", "Artists", { ArtistList.make(env) }),
            ("albums", "Albums", { AlbumList.make(env, sort: .alphabeticalByName) }),
            ("tracks", "Tracks", { TracksPage.make(env) }),
            ("genres", "Genres", { GenreList.make(env) }),
            ("more", "More", { more(env) }),
        ]
        let stack = Stack(transition: GTK_STACK_TRANSITION_TYPE_NONE)
        gtk_stack_set_hhomogeneous(stack.widget.cast(), 0)
        gtk_stack_set_vhomogeneous(stack.widget.cast(), 0)
        var built: Set<String> = []
        var switchers: [[ToggleButton]] = []

        func choose(_ name: String) {
            // Built on first showing: the tracks list alone is the whole library.
            if !built.contains(name), let tab = tabs.first(where: { $0.name == name }) {
                built.insert(name)
                let page = tab.page()
                if let header = page.header {
                    let toggles = tabs.map { other in
                        ToggleButton(other.title, "flat", "library-tab") { on in if on { choose(other.name) } }
                    }
                    for toggle in toggles.dropFirst() { toggle.group(with: toggles[0]) }
                    header.title(Box.horizontal(spacing: 2) { toggles }.css("library-tabs"))
                    switchers.append(toggles)
                    env.navigation.addButtons(to: page)
                }
                stack.add(page, name: name)
            }
            for toggles in switchers {
                for (toggle, tab) in zip(toggles, tabs) { toggle.isActive = tab.name == name }
            }
            stack.visibleName = name
            UserDefaults.standard.set(name, forKey: tabKey)
        }

        let remembered = UserDefaults.standard.string(forKey: tabKey)
        choose(tabs.contains { $0.name == remembered } ? remembered! : "albums")
        return NavigationPage(stack, title: "Library")
    }

    /// Every other way into the library.
    private static func more(_ env: Env) -> NavigationPage {
        let app = env.app
        func row(_ title: String, _ icon: String, _ destination: Destination) -> ActionRow {
            let row = ActionRow(title, icon: icon) { env.open(destination) }
            row.chevron()
            return row
        }

        let main = PreferencesGroup {
            row("Recently Played", "document-open-recent-symbolic", .albums(.recent))
            row("Most Played", "view-continuous-symbolic", .albums(.frequent))
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
            row("Duplicate Albums", "edit-copy-symbolic", .duplicateAlbums)
            row("Request Music", "list-add-symbolic", .requestMusic(""))
        }

        let recent = FlowBox(spacing: 12).columns(min: 2, max: 6).homogeneous()
        let recentGroup = PreferencesGroup("Recently Added").suffix(Button("See All", "flat", "see-all") { env.open(.albums(.newest)) })
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
        return Page.make("More", content: content) { bar in
            bar.end(ScopeMenu.make(app))
        }
    }
}
