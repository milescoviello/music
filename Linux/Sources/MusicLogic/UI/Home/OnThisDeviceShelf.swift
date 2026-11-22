import CGtk
import Foundation

/// Home with no server to be had: what plays here, first. Every download shuffled, then the
/// downloaded albums and playlists, newest first. The shelves below are saved copies, whose
/// songs may need the server; these never do.
@MainActor
enum OnThisDeviceShelf {
    static func make(_ env: Env) -> Widget? {
        let app = env.app
        guard app.isServerUnreachable else { return nil }
        let store = app.downloadFolders
        store.activate()
        let folders = store.folders
        guard !folders.songs.isEmpty else { return nil }
        let kept = (folders.playlists + folders.albums).sorted { $0.addedAt > $1.addedAt }.prefix(24)
        let cards = [shuffleCard(env, folders.songs)] + kept.map { card(env, $0) }
        return Shelf.make("On This Device", subtitle: "The server can't be reached: these play here", cards: cards)
    }

    private static func shuffleCard(_ env: Env, _ songs: [Song]) -> Widget {
        let side = AlbumCardView.side
        let covers = Array(Set(songs.compactMap(\.coverArt))).prefix(4)
        let box = Box.vertical(spacing: 6) {
            MixPages.tile(env.app, covers: Array(covers), side: side)
            Label("Shuffle Downloads", "card-title").ellipsize().maxWidthChars(1).hexpand()
            Label("\(songs.count) \(songs.count == 1 ? "song" : "songs")", "card-subtitle").ellipsize().maxWidthChars(1)
        }
        box.size(width: side).halign(GTK_ALIGN_CENTER)
        return Button(child: box, "card-button", "flat") {
            env.play(songs, source: "Downloads", shuffled: true)
        }
    }

    private static func card(_ env: Env, _ folder: DownloadFolders.Folder) -> Widget {
        let side = AlbumCardView.side
        let artwork = ArtworkView(env.app, size: .card, side: side, shape: .card)
        artwork.show(folder.coverArt, fallback: folder.name)
        let detail = folder.artist ?? "\(folder.songs.count) \(folder.songs.count == 1 ? "song" : "songs")"
        let box = Box.vertical(spacing: 6) {
            artwork.root
            Label(folder.name, "card-title").ellipsize().maxWidthChars(1).hexpand()
            Label(detail, "card-subtitle").ellipsize().maxWidthChars(1)
        }
        box.size(width: side).halign(GTK_ALIGN_CENTER)
        box.keep(artwork)
        return Button(child: box, "card-button", "flat") { env.open(.downloadFolder(folder.id)) }
    }
}
