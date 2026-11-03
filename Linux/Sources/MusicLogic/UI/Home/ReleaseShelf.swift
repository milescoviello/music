import CGtk
import Foundation

/// New releases by artists you play that the library does not have yet, from the sonic
/// service's radar. A click asks Hermes to get one.
@MainActor
enum ReleaseShelf {
    static func make(_ env: Env) -> Widget? {
        let radar = env.app.radar
        guard !radar.items.isEmpty else { return nil }
        return Shelf.make("New Releases", cards: radar.items.map { card(env, $0) })
    }

    private static func card(_ env: Env, _ item: SonicClient.RadarItem) -> Widget {
        let radar = env.app.radar
        let side = AlbumCardView.side
        let artwork = ArtworkView(env.app, size: .card, side: side, shape: .card)
        artwork.showRemote(item.cover, fallback: item.title)
        let requested = radar.requested.contains(item.id)
        let detail = Label(requested ? "Requested" : ReleaseRadar.detail(item), "caption", item.upcoming ? "accent" : "dim-label")
        let box = Box.vertical(spacing: 6) {
            artwork.root
            Label(item.title, "card-title").ellipsize().maxWidthChars(1).hexpand()
            Label(item.artist, "card-subtitle").ellipsize().maxWidthChars(1)
            detail.ellipsize().maxWidthChars(1)
        }
        box.size(width: side).halign(GTK_ALIGN_CENTER)
        box.keep(artwork)
        return Button(child: box, "card-button", "flat") { ask(env, item) }
    }

    private static func ask(_ env: Env, _ item: SonicClient.RadarItem) {
        let radar = env.app.radar
        guard radar.canRequest else {
            env.toast("\(ReleaseRadar.detail(item)). Set up requests in Settings to ask Hermes for it.")
            return
        }
        Dialogs.alert(
            "“\(item.title)” by \(item.artist)",
            body: "\(ReleaseRadar.detail(item)). Hermes will look for it and add it to the library.",
            responses: [("cancel", "Cancel", ADW_RESPONSE_DEFAULT), ("request", "Request It", ADW_RESPONSE_SUGGESTED)]
        ) { response in
            guard response == "request" else { return }
            Task { @MainActor in
                let sent = await radar.request(item)
                env.toast(sent ? "Asked Hermes for “\(item.title)”" : "Couldn't send the request")
            }
        }
    }
}
