import CGtk
import Foundation

/// The bar along the bottom of the window: what is playing, play and skip, and a thin line
/// for how far through it is. Clicking anywhere else on it opens the player, as tapping
/// the phone's does; scrolling sideways skips.
@MainActor
final class MiniPlayer {
    let root: Widget

    init(app: AppState) {
        let player = app.player
        let artwork = ArtworkView(app, size: .thumb, side: 40, shape: .thumb)
        let title = Label("", "title").ellipsize()
        let artist = Label("", "caption", "dim").ellipsize()
        let previous = Button(icon: "media-skip-backward-symbolic", "flat", "circular") { player.previous() }
        let play = Button(icon: "media-playback-start-symbolic", "flat", "circular") { player.togglePlayPause() }
        let next = Button(icon: "media-skip-forward-symbolic", "flat", "circular") { player.next() }
        previous.tooltip("Previous")
        next.tooltip("Next")

        let progress = DrawingArea(height: 2) { cairo, width, height in
            let fraction = player.duration > 0 ? min(max(player.elapsed / player.duration, 0), 1) : 0
            cairo.color(Style.tint)
            cairo.rectangle(0, 0, width * fraction, height)
            cairo.fill()
        }
        progress.hexpand()

        let row = Box.horizontal(spacing: 12) {
            artwork.root
            Box.vertical(spacing: 0) {
                title
                artist
            }.hexpand().valign(GTK_ALIGN_CENTER)
            previous
            play
            next
        }.css("mini-player")

        let box = Box.vertical {
            row
            progress
        }
        root = box

        box.observe {
            guard let song = player.currentSong else { return }
            title.text = song.title
            artist.text = song.artist ?? ""
            artwork.show(song.coverArt, fallback: song.album ?? song.title)
        }
        box.observe {
            play.icon = player.isPlaying ? "media-playback-pause-symbolic" : "media-playback-start-symbolic"
            play.tooltip(player.isPlaying ? "Pause" : "Play")
        }
        box.observe {
            _ = player.elapsed
            _ = player.duration
            progress.redraw()
        }

        // Sideways to skip, the gesture Plexamp and Apple Music both use.
        let scroll = gtk_event_controller_scroll_new(GTK_EVENT_CONTROLLER_SCROLL_HORIZONTAL)!
        var accumulated = 0.0
        Signal.connect(scroll, "scroll", scroll: { dx, _ in
            accumulated += dx
            if accumulated > 3 {
                accumulated = 0
                player.next()
            } else if accumulated < -3 {
                accumulated = 0
                player.previous()
            }
            return true
        })
        gtk_widget_add_controller(row.widget, scroll)
    }
}
