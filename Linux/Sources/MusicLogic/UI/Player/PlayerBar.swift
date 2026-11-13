import CGtk
import Foundation

/// The bar along the bottom of the window while browsing, frosted glass over the
/// backdrop: the song and its heart on the left; shuffle, the transport and repeat over
/// the song's loudness in the middle; lyrics, the queue, Play On and the volume on the
/// right. Clicking it anywhere that is not a button opens the player, as the mini player
/// did; scrolling sideways skips.
@MainActor
final class PlayerBar {
    let root: Widget

    init(env: Env, player nowPlaying: NowPlaying) {
        let app = env.app
        let player = app.player
        let artwork = ArtworkView(app, size: .thumb, side: 56, shape: .thumb)
        let title = Label("", "bar-title").xalign(0).ellipsize().maxWidthChars(28)
        let artist = Label("", "bar-artist").xalign(0).ellipsize().maxWidthChars(28)
        let heart = Button(icon: "music-heart-symbolic", "flat", "circular", "bar-heart") {
            guard let song = player.currentSong else { return }
            app.userState.toggleStar(song)
        }
        let song = Box.horizontal(spacing: 12) {
            artwork.root
            Box.vertical(spacing: 2) {
                title
                artist
            }.valign(GTK_ALIGN_CENTER)
            heart.valign(GTK_ALIGN_CENTER)
        }.halign(GTK_ALIGN_START)

        let previous = Button(icon: "media-skip-backward-symbolic", "flat", "circular") { player.previous() }
        let play = Button(icon: "media-playback-start-symbolic", "circular", "bar-play") { player.togglePlayPause() }
        let next = Button(icon: "media-skip-forward-symbolic", "flat", "circular") { player.next() }
        previous.tooltip("Previous")
        next.tooltip("Next")
        let shuffle = NowPlaying.shuffleButton(app)
        let repeatButton = NowPlaying.repeatButton(app)
        let transport = Box.horizontal(spacing: 10) {
            shuffle
            previous
            play
            next
            repeatButton
        }.halign(GTK_ALIGN_CENTER)
        for button in [previous, play, next] { button.valign(GTK_ALIGN_CENTER) }
        let seek = SeekBar(app: app, desktop: true).root.size(width: 300, height: -1)
        let middle = Box.vertical(spacing: 0) {
            transport
            seek
        }.valign(GTK_ALIGN_CENTER).margin(horizontal: 16, vertical: 0)

        let lyrics = Button(icon: "format-justify-left-symbolic", "flat", "circular") { nowPlaying.open(.lyrics) }
        let queue = Button(icon: "view-list-symbolic", "flat", "circular") { nowPlaying.openQueue() }
        lyrics.tooltip("Lyrics")
        queue.tooltip("Up Next")
        let volume = NowPlaying.volumeRow().size(width: 110, height: -1)
        let playOn = PlayOn.button(env)
        let tools = Box.horizontal(spacing: 4) {
            lyrics
            queue
            playOn
            volume
        }.halign(GTK_ALIGN_END).valign(GTK_ALIGN_CENTER)

        // The transport stays in the middle however wide the two sides are; what does not
        // fit goes, least needed first: the volume, then Play On, lyrics and the queue,
        // then the seekbar, shuffle and repeat, down to the phone's bar of the song and its
        // buttons.
        let center = CenterBox(start: song, center: middle, end: tools)
        let bar = Box.vertical(spacing: 0) {
            Widths.watch { width in
                volume.isVisible = width >= 960
                for button in [lyrics, queue, playOn] { button.isVisible = width >= 720 }
                for piece in [shuffle, repeatButton, seek] { piece.isVisible = width >= 560 }
            }
            center
        }.css("player-bar")
        root = bar

        bar.observe {
            guard let song = player.currentSong else { return }
            title.text = song.title
            artist.text = song.artist ?? ""
            artwork.show(song.coverArt, fallback: song.album ?? song.title)
        }
        bar.observe {
            play.icon = player.isPlaying ? "media-playback-pause-symbolic" : "media-playback-start-symbolic"
            play.tooltip(player.isPlaying ? "Pause" : "Play")
        }
        bar.observe {
            let starred = player.currentSong.map { app.userState.isStarred($0) } ?? false
            heart.setCSS("filled", starred)
            heart.tooltip(starred ? "Unlove" : "Love")
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
        gtk_widget_add_controller(song.widget, scroll)
    }
}
