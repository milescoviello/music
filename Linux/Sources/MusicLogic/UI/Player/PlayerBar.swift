import CGtk
import Foundation

/// The bar along the bottom of the window while browsing, frosted glass over the
/// backdrop: the song and its heart on the left; shuffle, the transport and repeat over
/// the song's loudness in the middle; lyrics, the queue, Play On and the volume on the
/// right. Clicking it anywhere that is not a button opens the player, as the mini player
/// did; scrolling sideways skips. A YouTube result shrunk out of its window plays on in
/// the song's place: a click brings the window back, and the cross ends it.
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
        // The shrunk video, live, at the cover's height. Held at exactly that size, as the
        // YouTube thumbnails are: a picture asks for its frame's size, and would take the bar.
        let videoSurface = VideoSurfaceView(app)
        let videoFrame = ScrolledWindow(videoSurface.root, horizontal: GTK_POLICY_EXTERNAL, vertical: GTK_POLICY_EXTERNAL)
        videoFrame.size(width: 100, height: 56)
        gtk_scrolled_window_set_max_content_width(videoFrame.widget.cast(), 100)
        gtk_scrolled_window_set_max_content_height(videoFrame.widget.cast(), 56)
        let video = Overlay(videoFrame).css("bar-video")
        video.clipped().halign(GTK_ALIGN_START).valign(GTK_ALIGN_CENTER).hexpand(false).vexpand(false)
        video.isVisible = false
        let closeVideo = Button(icon: "window-close-symbolic", "flat", "circular") { app.video.stopWatching() }
        closeVideo.tooltip("Close Video").valign(GTK_ALIGN_CENTER)
        closeVideo.isVisible = false
        let song = Box.horizontal(spacing: 12) {
            artwork.root
            video
            Box.vertical(spacing: 2) {
                title
                artist
            }.valign(GTK_ALIGN_CENTER)
            heart.valign(GTK_ALIGN_CENTER)
            closeVideo
        }.halign(GTK_ALIGN_START)
        song.onClick {
            if app.video.isWatchingMinimized, let watching = app.video.watching {
                app.video.expandWatching()
                VideoWindow.present(app, watching: watching, toast: env.toast)
            } else {
                app.navigator.showsPlayer = true
            }
        }
        gtk_widget_set_cursor_from_name(song.widget, "pointer")

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

        let lyrics = Button(icon: "music-lyrics-symbolic", "flat", "circular") { nowPlaying.open(.lyrics) }
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
            let shrunk = app.video.isWatchingMinimized ? app.video.watching : nil
            video.isVisible = shrunk != nil
            closeVideo.isVisible = shrunk != nil
            artwork.root.isVisible = shrunk == nil
            heart.isVisible = shrunk == nil
            if let shrunk {
                title.text = shrunk.title
                artist.text = shrunk.channel
                return
            }
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
