import CGtk
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Albums held in both libraries, side by side, weakest copy first: format, depth and
/// rate, tracks, plays, size and folder, for deciding by hand which to keep. A copy opens
/// its album. Nothing here moves or deletes anything (`duplicates.py`, on the service).
@MainActor
enum DuplicateAlbumsPage {
    static func make(_ env: Env) -> NavigationPage {
        let loader = Loader()
        let sonic = SonicClient(configuration: env.app.sonic.configuration)
        loader.run({ try? await sonic.duplicateAlbums() }) { pairs in
            guard !pairs.isEmpty else {
                return Loader.empty("No Duplicates", icon: "emblem-ok-symbolic",
                                    description: "No album is in both libraries.")
            }
            let content = Box.vertical(spacing: 24).margin(horizontal: 12, vertical: 24)
            content.append(Label(summary(pairs), "dim").wrap().xalign(0))
            for pair in pairs { content.append(group(env, pair)) }
            return content
        }
        return Page.make("Duplicate Albums", content: loader.bin)
    }

    static func summary(_ pairs: [SonicClient.DuplicateAlbum]) -> String {
        let alike = pairs.filter(\.alike).count
        let albums = pairs.count == 1 ? "1 album is" : "\(pairs.count) albums are"
        return "\(albums) in both libraries; \(alike) of them the same quality in both. The weaker copy is first."
    }

    private static func group(_ env: Env, _ pair: SonicClient.DuplicateAlbum) -> Widget {
        let group = PreferencesGroup(pair.name, description: pair.alike ? "\(pair.artist) · the same in both" : pair.artist)
        for (index, copy) in pair.copies.enumerated() {
            let weaker = index == 0 && !pair.alike
            let title = "\(copy.library) · \(copy.format)"
            let row = ActionRow(title, subtitle: details(copy)) {
                env.open(.album(AlbumRef(id: copy.albumId, name: copy.name, artist: copy.artist)))
            }
            row.titleLines(2)
            if weaker { row.suffix(Label("Weaker", "caption", "warning").valign(GTK_ALIGN_CENTER)) }
            row.suffix(Icon("go-next-symbolic").valign(GTK_ALIGN_CENTER))
            group.add(row)
        }
        return group
    }

    static func details(_ copy: SonicClient.DuplicateAlbum.Copy) -> String {
        [
            "\(copy.tracks) \(copy.tracks == 1 ? "track" : "tracks")",
            "\(copy.plays) \(copy.plays == 1 ? "play" : "plays")",
            copy.size.asFileSize,
            copy.folder,
        ].joined(separator: " · ")
    }
}

/// Home's Shows Near You: concerts coming up by the artists played most (`NearbyShows`).
/// A card opens the ticket page in the browser.
@MainActor
enum ShowsShelf {
    static func make(_ env: Env) -> Widget? {
        let items = env.app.shows.items
        guard !items.isEmpty else { return nil }
        return Shelf.make("Shows Near You", cards: items.map { card(env, $0) })
    }

    private static func card(_ env: Env, _ show: SonicClient.Show) -> Widget {
        let side = AlbumCardView.side
        let artwork = ArtworkView(env.app, size: .card, side: side, shape: .card)
        artwork.showRemote(fallback: show.artist) {
            guard let image = show.image, let url = URL(string: image) else { return nil }
            return try? await URLSession.shared.data(from: url).0
        }
        let box = Box.vertical(spacing: 6) {
            artwork.root
            Label(show.artist, "card-title").ellipsize().maxWidthChars(1).hexpand()
            Label(NearbyShows.when(show), "card-subtitle", "accent").ellipsize().maxWidthChars(1)
            Label(NearbyShows.place(show), "caption", "dim-label").ellipsize().maxWidthChars(1)
        }
        box.size(width: side).halign(GTK_ALIGN_CENTER)
        box.keep(artwork)
        return Button(child: box, "card-button", "flat") {
            g_app_info_launch_default_for_uri(show.url, nil, nil)
        }.tooltip(show.name)
    }
}
