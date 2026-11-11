import CGtk
import Foundation

/// The download control for a whole album or playlist, Plexamp's toggle: one click
/// downloads it, a ring fills while it arrives, a check once it is all here, and clicking
/// the ring or the check removes it.
@MainActor
final class CollectionDownloadButton {
    let root: Button
    private let env: Env
    private let groupID: String
    private let groupName: String
    private let songs: @MainActor () -> [Song]
    private var fraction: Double?
    private var complete = false
    private var ring: DrawingArea?

    init(_ env: Env, groupID: String, groupName: String, songs: @escaping @MainActor () -> [Song]) {
        self.env = env
        self.groupID = groupID
        self.groupName = groupName
        self.songs = songs
        let reference = WeakReference<CollectionDownloadButton>(nil)
        let ring = DrawingArea(width: 20, height: 20) { cairo, width, height in
            reference.value?.draw(cairo, width: width, height: height)
        }
        root = Button(child: ring, "flat")
        self.ring = ring
        reference.value = self
        root.keep(self)
        root.onClicked { reference.value?.toggle() }
        root.observe {
            guard let button = reference.value else { return }
            _ = env.app.downloads.catalog
            _ = env.app.downloads.progress
            _ = env.app.downloads.asking
            button.refresh()
            ring.redraw()
        }
    }

    /// Its songs arrived or changed. A page loads them after building the button, and the
    /// button only looks again when a download changes: it stayed greyed out, and a
    /// downloaded album showed the plain arrow, until something downloaded.
    func songsChanged() {
        refresh()
        ring?.redraw()
    }

    private func refresh() {
        let list = songs()
        // This album's or playlist's own download only; see `DownloadCatalog.collectionState`.
        switch env.app.downloads.collectionState(of: list, groupID: groupID) {
        case let .working(value):
            fraction = value
            complete = false
            root.tooltip("Downloading — click to remove")
        case .complete:
            fraction = nil
            complete = true
            root.tooltip("Downloaded — click to remove")
        case .none:
            fraction = nil
            complete = false
            root.tooltip("Download")
        }
        root.isSensitive = !list.isEmpty
    }

    private func toggle() {
        let list = songs()
        let downloads = env.app.downloads
        if fraction == nil, !complete {
            downloads.download(list, groupID: groupID, groupName: groupName)
        } else {
            // Songs another downloaded album or playlist has stay, and only leave this one.
            env.app.playlistSync.stopSyncing(groupID: groupID)
            downloads.removeGroup(groupID)
        }
    }

    private func draw(_ cairo: Cairo, width: Double, height: Double) {
        let centre = (width / 2, height / 2)
        let radius = min(width, height) / 2 - 2
        if let fraction {
            cairo.color(Style.tint, alpha: 0.25)
            cairo_arc(cairo.context, centre.0, centre.1, radius, 0, 2 * .pi)
            cairo.stroke(width: 2.5)
            cairo.color(Style.tint)
            cairo_arc(cairo.context, centre.0, centre.1, radius, -.pi / 2, -.pi / 2 + 2 * .pi * max(0.03, min(fraction, 1)))
            cairo.stroke(width: 2.5)
            cairo.roundedRectangle(centre.0 - 3.5, centre.1 - 3.5, 7, 7, radius: 1.5)
            cairo.fill()
        } else if complete {
            cairo.color(Style.tint)
            cairo_arc(cairo.context, centre.0, centre.1, radius + 1, 0, 2 * .pi)
            cairo.fill()
            cairo.color(red: 1, green: 1, blue: 1)
            cairo.move(centre.0 - 4, centre.1)
            cairo.line(centre.0 - 1, centre.1 + 3)
            cairo.line(centre.0 + 4.5, centre.1 - 3.5)
            cairo.stroke(width: 2)
        } else {
            cairo.color(red: 1, green: 1, blue: 1, alpha: 0.75)
            cairo_arc(cairo.context, centre.0, centre.1, radius, 0, 2 * .pi)
            cairo.stroke(width: 1.5)
            cairo.move(centre.0, centre.1 - 4.5)
            cairo.line(centre.0, centre.1 + 3.5)
            cairo.move(centre.0 - 3.5, centre.1)
            cairo.line(centre.0, centre.1 + 3.5)
            cairo.line(centre.0 + 3.5, centre.1)
            cairo.stroke(width: 1.5)
        }
    }
}
