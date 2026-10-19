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
        reference.value = self
        root.keep(self)
        root.onClicked { reference.value?.toggle() }
        root.observe {
            guard let button = reference.value else { return }
            _ = env.app.downloads.catalog
            _ = env.app.downloads.progress
            button.refresh()
            ring.redraw()
        }
    }

    private func refresh() {
        let list = songs()
        let downloads = env.app.downloads
        var downloaded = 0
        var arriving = 0
        var transferred = 0.0
        for song in list {
            switch downloads.status(for: song.id) {
            case .downloaded: downloaded += 1
            case .waiting: arriving += 1
            case let .downloading(value):
                arriving += 1
                transferred += value
            case .none: break
            }
        }
        if arriving > 0 {
            fraction = (Double(downloaded) + transferred) / Double(max(list.count, 1))
            complete = false
            root.tooltip("Downloading — click to remove")
        } else {
            fraction = nil
            complete = !list.isEmpty && downloaded == list.count
            root.tooltip(complete ? "Downloaded — click to remove" : "Download")
        }
        root.isSensitive = !list.isEmpty
    }

    private func toggle() {
        let list = songs()
        let downloads = env.app.downloads
        if fraction == nil, !complete {
            downloads.download(list, groupID: groupID, groupName: groupName)
        } else {
            env.app.playlistSync.stopSyncing(groupID: groupID)
            let own = downloads.catalog.songIDs(downloadedAs: groupID)
            downloads.remove(own.isEmpty ? list.map(\.id) : own)
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
