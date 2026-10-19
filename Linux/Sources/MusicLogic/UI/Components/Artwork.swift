import CGtk
import Foundation

/// Cover art, square and rounded, with the phone's placeholder: the album's initials when
/// there is no cover — 274 albums in this library have none, and a grid of identical
/// notes is the worst way to show that.
///
/// A cover already in memory is drawn at once, with no placeholder at all; a miss loads in
/// the background and lands only if the view still shows the same cover by then, which is
/// what keeps a recycled grid cell from flashing the previous album.
@MainActor
final class ArtworkView {
    enum Shape {
        case thumb, card, player, round
    }

    let root: Overlay
    private let picture: Canvas
    private let placeholder: Box
    private let monogram: Label
    private let icon: Icon
    private let store: ArtworkStore
    private let playlistArtwork: PlaylistArtwork?
    private let size: ArtworkStore.Size
    private var token = 0
    private(set) var shownID: String?

    /// `side` fixes the size; nil lets the view take the space it is given.
    init(_ app: AppState, size: ArtworkStore.Size, side: Int32?, shape: Shape) {
        store = app.artwork
        playlistArtwork = app.playlistArtwork
        self.size = size

        monogram = Label("", "monogram").xalign(0.5).halign(GTK_ALIGN_CENTER).valign(GTK_ALIGN_CENTER)
        icon = Icon("audio-x-generic-symbolic", size: max(16, (side ?? 64) / 3)).opacity(0.4)
            .halign(GTK_ALIGN_CENTER).valign(GTK_ALIGN_CENTER)
        placeholder = Box.vertical {}.css("artwork-placeholder")
        let centre = Overlay(placeholder).add(icon).add(monogram)

        // A fixed size is drawn as an image of that size: a `GtkPicture` asks for its
        // texture's own size, so a 512-pixel cover would push a 160-pixel slot wider.
        picture = side.map { Canvas.fixed($0) } ?? Canvas.flexible()
        root = Overlay(centre)
        root.add(picture.widget).clipped().css("artwork")
        switch shape {
        case .thumb: root.css("thumb")
        case .card: break
        case .player: root.css("player")
        case .round: root.css("round")
        }
        if let side {
            root.size(width: side, height: side).halign(GTK_ALIGN_CENTER).valign(GTK_ALIGN_CENTER)
            // Initials scaled to the box, as the phone scales its text to fill it.
            let points = max(9, Int(Double(side) * 0.32))
            monogram.setMarkup("<span size=\"\(points * 1024)\">\(Markup.escape(""))</span>")
            monogramPoints = points
        }
        root.keep(self)
    }

    private var monogramPoints = 24

    /// Shows a cover. `playlistID` lets a chosen playlist photo win; `fallback` is the
    /// name to draw initials from.
    func show(_ id: String?, playlistID: String? = nil, fallback: String? = nil) {
        token += 1
        let current = token
        shownID = id
        setFallback(fallback)

        if let playlistID, let custom = playlistArtwork?.image(for: playlistID) {
            picture.set(custom)
            return
        }
        if let hit = store.cached(id, size) {
            picture.set(hit)
            return
        }
        picture.set(nil)
        guard id != nil else { return }
        let reference = WeakReference(self)
        let store = store
        let size = size
        Task { @MainActor in
            let texture = await store.image(for: id, size: size)
            guard let view = reference.value, view.token == current else { return }
            view.picture.set(texture)
        }
    }

    private func setFallback(_ text: String?) {
        let letters = text?.monogram ?? ""
        monogram.setMarkup(letters.isEmpty ? "" : "<span size=\"\(monogramPoints * 1024)\">\(Markup.escape(letters))</span>")
        icon.isVisible = letters.isEmpty
    }
}

/// Where a cover is drawn: an image at a fixed size, or a picture that fills its slot.
@MainActor
private enum Canvas {
    case fixed(Widget)
    case flexible(Picture)

    static func fixed(_ side: Int32) -> Canvas {
        let image = Widget(gtk_image_new()!)
        gtk_image_set_pixel_size(image.widget.cast(), side)
        return .fixed(image)
    }

    static func flexible() -> Canvas {
        .flexible(Picture())
    }

    var widget: Widget {
        switch self {
        case let .fixed(image): return image
        case let .flexible(picture): return picture
        }
    }

    func set(_ texture: Texture?) {
        switch self {
        case let .fixed(image):
            if let texture {
                gtk_image_set_from_paintable(image.widget.cast(), texture.paintable)
            } else {
                gtk_image_clear(image.widget.cast())
            }
        case let .flexible(picture):
            picture.set(texture)
        }
    }
}

extension String {
    /// "Red Hot Chili Peppers" -> "RH"
    var monogram: String {
        let words = split(separator: " ").prefix(2)
        return words.compactMap { $0.first }.map(String.init).joined().uppercased()
    }
}
