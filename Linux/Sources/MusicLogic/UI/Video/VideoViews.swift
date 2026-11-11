import CGtk
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// The desktop's music-video screens, over the shared `VideoService`: the picture, a row for
// a YouTube result, Add to Library, Change Video, the video window (full screen, and for
// watching a search result), and Search's YouTube side.

/// The video's picture, drawn on every frame the widget is: each surface asks the engine
/// for the picture due now. While no surface is on screen the engine skips the pictures.
@MainActor
final class VideoSurfaceView {
    let root: Overlay
    private let picture = Picture().fit(GTK_CONTENT_FIT_CONTAIN)
    private let engine: VideoEngine
    private var tickID: guint = 0
    private var attached = false
    private var shown: Texture?

    init(_ app: AppState) {
        engine = app.video.engine
        picture.hexpand().vexpand()
        let backing = Bin(picture).css("video-surface")
        backing.hexpand().vexpand()
        root = Overlay(backing)
        let spinner = Spinner().size(36)
        spinner.halign(GTK_ALIGN_CENTER).valign(GTK_ALIGN_CENTER).canTarget(false)
        root.add(spinner)
        spinner.observe {
            let video = app.video
            spinner.isVisible = video.current != nil && (video.progress.isWaiting || video.showing == .loading)
        }
        root.keep(self)
        let reference = WeakReference(self)
        root.onMap { reference.value?.setMapped(true) }
        root.onUnmap { reference.value?.setMapped(false) }
    }

    private func setMapped(_ mapped: Bool) {
        if mapped, !attached {
            attached = true
            engine.attachSurface()
            show(engine.present())
            let reference = WeakReference(self)
            tickID = tick(picture) { reference.value?.frame() ?? false }
        } else if !mapped, attached {
            attached = false
            engine.detachSurface()
            if tickID != 0 {
                gtk_widget_remove_tick_callback(picture.widget, tickID)
                tickID = 0
            }
        }
    }

    private func frame() -> Bool {
        show(engine.present())
        return true
    }

    private func show(_ texture: Texture?) {
        guard texture !== shown else { return }
        shown = texture
        picture.set(texture)
    }
}

/// A YouTube thumbnail at a fixed 16:9 size, with the length in its corner.
@MainActor
enum VideoThumbnail {
    private static var cache: [String: Texture] = [:]

    static func make(_ app: AppState, _ video: VideoClient.Video, width: Int32 = 160) -> Widget {
        let height = width * 9 / 16
        let picture = Picture().fit(GTK_CONTENT_FIT_COVER)
        // Held at exactly this size: a picture's natural size is its image's. And never
        // asked to expand: that would spread to the row and take its spare width.
        let frame = ScrolledWindow(picture, horizontal: GTK_POLICY_EXTERNAL, vertical: GTK_POLICY_EXTERNAL)
        frame.size(width: width, height: height)
        gtk_scrolled_window_set_max_content_width(frame.widget.cast(), width)
        gtk_scrolled_window_set_max_content_height(frame.widget.cast(), height)
        let root = Overlay(frame).css("video-thumb")
        root.clipped().halign(GTK_ALIGN_START).valign(GTK_ALIGN_CENTER).hexpand(false).vexpand(false)
        if let length = video.durationText {
            root.add(Label(length, "video-length").halign(GTK_ALIGN_END).valign(GTK_ALIGN_END).margin(4))
        }
        if let kept = cache[video.id] {
            picture.set(kept)
        } else if let url = app.video.client.thumbnailURL(videoID: video.id) {
            let id = video.id
            let alive = picture.liveness
            Task { @MainActor in
                guard let (data, _) = try? await URLSession.shared.data(from: url) else { return }
                let texture = await Task.detached { Texture(data: data) }.value
                guard let texture else { return }
                if cache.count > 400 { cache.removeAll() }
                cache[id] = texture
                if alive.isAlive { picture.set(texture) }
            }
        }
        return root
    }
}

/// A video in a list: thumbnail, title, channel and length.
@MainActor
enum VideoRow {
    static func make(
        _ app: AppState,
        _ video: VideoClient.Video,
        isChosen: Bool = false,
        note: String? = nil,
        suffix: Widget? = nil,
        action: @escaping @MainActor () -> Void
    ) -> Widget {
        let subtitle = [video.verified == true ? "✓ \(video.channel)" : video.channel, video.durationText]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        let text = Box.vertical(spacing: 3) {
            Label(video.title, isChosen ? "video-title-chosen" : "video-title").ellipsize().xalign(0).halign(GTK_ALIGN_START)
            Label(subtitle, "caption", "dim-label").ellipsize().xalign(0).halign(GTK_ALIGN_START)
        }
        if let note { text.append(Label(note, "caption", "accent").xalign(0).halign(GTK_ALIGN_START)) }
        text.hexpand().halign(GTK_ALIGN_FILL).valign(GTK_ALIGN_CENTER)
        let row = Box.horizontal(spacing: 12) {
            VideoThumbnail.make(app, video)
            text
        }
        if isChosen { row.append(Icon("object-select-symbolic").css("accent").valign(GTK_ALIGN_CENTER)) }
        let button = Button(child: row.margin(horizontal: 6, vertical: 4), "flat", "video-row", action: action)
        button.hexpand()
        guard let suffix else { return button }
        return Box.horizontal(spacing: 4) {
            button
            suffix.valign(GTK_ALIGN_CENTER)
        }
    }
}

/// Add to Library for a video: the song alone, or the song and then its album, asked each
/// time, sent through Hermes to the Soulseek pipeline.
@MainActor
enum AddVideoToLibrary {
    static func ask(_ app: AppState, _ video: VideoClient.Video, toast: @escaping @MainActor (String) -> Void, over parent: Widget? = nil) {
        let requests = app.requests
        let artist = video.artist ?? video.channel
        let song = video.song ?? video.title
        guard requests.isConfigured else {
            toast("Set up Music Requests in Settings to add songs from YouTube.")
            return
        }
        Dialogs.alert(
            artist.isEmpty ? "Add “\(song)”" : "Add “\(song)” by \(artist)",
            body: "Hermes gets it as lossless through Soulseek. The song comes first, so it's playable within minutes.",
            responses: [
                ("cancel", "Cancel", ADW_RESPONSE_DEFAULT),
                ("album", "Song + Album", ADW_RESPONSE_DEFAULT),
                ("song", "Song", ADW_RESPONSE_SUGGESTED),
            ],
            defaultResponse: "song",
            over: parent
        ) { response in
            guard response == "song" || response == "album" else { return }
            let withAlbum = response == "album"
            Task { @MainActor in
                let sent = await requests.sendSong(artist: artist, title: song, withAlbum: withAlbum, videoID: video.id)
                toast(sent
                    ? (withAlbum ? "Asked for “\(song)”, then its album" : "Asked for “\(song)”")
                    : (requests.lastError ?? "The request didn't go through."))
            }
        }
    }
}

/// Change Video: YouTube's results for the song, a search for anything typed, or a pasted
/// link. The choice is kept by the service, on every device.
@MainActor
enum ChangeVideo {
    static func present(_ app: AppState, song: Song, toast: @escaping @MainActor (String) -> Void) {
        let videos = app.video
        let entry = SearchEntry(placeholder: "Search YouTube or paste a link").searchDelay(400)
        let current = Box.vertical(spacing: 6)
        let list = Box.vertical(spacing: 2)
        let status = Label("", "dim-label").xalign(0)
        let stack = Stack()
        stack.add(Spinner().size(32).halign(GTK_ALIGN_CENTER).valign(GTK_ALIGN_START).margin(36), name: "loading")
        stack.add(list, name: "results")
        var dialog: OpaquePointer?
        var generation = 0

        func save(_ action: @escaping @MainActor () async -> Bool) {
            Task { @MainActor in
                if await action() {
                    if let dialog { Dialogs.close(dialog) }
                } else {
                    toast("Couldn't save the video choice.")
                }
            }
        }

        func showCurrent() {
            current.removeAll()
            guard case let .found(match) = videos.lookup(for: song), let chosen = match.video else {
                current.isVisible = false
                return
            }
            current.isVisible = true
            current.append(Label("Playing Now", "heading").xalign(0))
            current.append(VideoRow.make(app, chosen, isChosen: true,
                                         note: match.manual ? "Chosen by you" : "Picked automatically") {})
            if match.manual {
                current.append(Button("Use the Automatic Pick", icon: "starred-symbolic", "pill") {
                    save { await videos.useAutomatic(for: song) }
                }.halign(GTK_ALIGN_START))
            }
        }

        func load(_ text: String) {
            generation += 1
            let mine = generation
            stack.visibleName = "loading"
            let alive = list.liveness
            Task { @MainActor in
                let found = await videos.candidates(for: song, query: text)
                guard alive.isAlive, mine == generation else { return }
                list.removeAll()
                let chosenID = videos.lookup(for: song)?.video?.id
                for video in found {
                    list.append(VideoRow.make(app, video, isChosen: video.id == chosenID) {
                        save { await videos.choose(video, for: song) }
                    })
                }
                status.text = found.isEmpty ? "No videos found. Try other words, or paste a YouTube link." : ""
                status.isVisible = found.isEmpty
                stack.visibleName = "results"
            }
        }

        entry.onSearch { load($0) }
        let body = Box.vertical(spacing: 12) {
            current
            entry
            status
            stack
            Label("Your choice is kept for this song on every device.", "caption", "dim-label").xalign(0)
        }.margin(16)
        showCurrent()
        load("")
        let content = ScrolledWindow(Clamp(body, maximum: 640)).vexpand()
        dialog = Dialogs.sheet("Change Video", content: content, width: 620, height: 680)
        entry.grabFocus()
    }
}

/// The video in a window of its own, which goes full screen: a YouTube result being watched
/// from search, or the song's video from the player. Watching, the controls are the
/// video's own with Add to Library, and closing it puts the music back where it was; for
/// the song's video they are the player's, and closing leaves it playing in the player.
@MainActor
final class VideoWindow {
    private static var open: VideoWindow?

    private let app: AppState
    private let watching: VideoClient.Video?
    private let window: UnsafeMutablePointer<GtkWidget>
    private let controls: Revealer
    private var hideTask: Task<Void, Never>?
    private var isFullScreen = false
    /// What the window manager last said, for telling when it took full screen away.
    private var wasFullScreen = false
    private var dragging = false

    /// Opens it full screen, or brings the one already open forward. It is only ever full
    /// screen: leaving it closes it, back into the app -- a song's video into the player,
    /// a watched one to where it was found, with the music picking up again. Out of full
    /// screen it was a small window over the app, which nobody wanted.
    static func present(_ app: AppState, watching: VideoClient.Video?, toast: @escaping @MainActor (String) -> Void) {
        if let open {
            if open.watching?.id == watching?.id {
                gtk_window_present(open.window.cast())
                open.setFullScreen(true)
                return
            }
            open.close()
        }
        let created = VideoWindow(app, watching: watching, toast: toast)
        open = created
        gtk_window_present(created.window.cast())
        created.setFullScreen(true)
    }

    /// Closes it from elsewhere -- the watched video was closed another way.
    static func dismiss() {
        open?.close()
    }

    private init(_ app: AppState, watching: VideoClient.Video?, toast: @escaping @MainActor (String) -> Void) {
        self.app = app
        self.watching = watching
        window = adw_window_new()!
        gtk_window_set_title(window.cast(), watching?.title ?? app.player.currentSong?.title ?? "Video")
        gtk_window_set_default_size(window.cast(), 1120, 660)
        if let main = Desktop.window { gtk_window_set_transient_for(window.cast(), main.cast()) }
        gtk_widget_add_css_class(window, "video-window")

        let surface = VideoSurfaceView(app)
        let reference = WeakReference<VideoWindow>(nil)

        // The controls, over the bottom of the picture.
        let title = Label("", "video-window-title").ellipsize().xalign(0)
        let subtitle = Label("", "video-window-subtitle").ellipsize().xalign(0)
        let elapsed = Label("0:00", "numeric", "video-time")
        let length = Label("0:00", "numeric", "video-time")
        let scale = Scale(min: 0, max: 1, step: 1, value: 0)
        scale.hexpand().css("video-seek")
        let playButton = Button(icon: "media-playback-start-symbolic", "circular", "video-play") {
            reference.value?.togglePlay()
        }
        let back = watching == nil
            ? Button(icon: "media-skip-backward-symbolic", "flat", "circular") { app.player.previous() }
            : Button(icon: "media-seek-backward-symbolic", "flat", "circular") { app.video.skip(by: -10) }
        let forward = watching == nil
            ? Button(icon: "media-skip-forward-symbolic", "flat", "circular") { app.player.next() }
            : Button(icon: "media-seek-forward-symbolic", "flat", "circular") { app.video.skip(by: 10) }
        back.tooltip(watching == nil ? "Previous" : "Back 10 Seconds")
        forward.tooltip(watching == nil ? "Next" : "Forward 10 Seconds")
        let ends = Box.horizontal(spacing: 4)
        if let watching {
            ends.append(Button(icon: "list-add-symbolic", "flat", "circular") {
                AddVideoToLibrary.ask(app, watching, toast: toast)
            }.tooltip("Add to Library"))
        }
        // Out of full screen is closing, so one button: back into the app.
        let leave = watching == nil ? "Back to the Player" : "Close"
        ends.append(Button(icon: "view-restore-symbolic", "flat", "circular") { reference.value?.close() }.tooltip(leave))

        let bar = Box.vertical(spacing: 6) {
            Box.horizontal(spacing: 12) {
                Box.vertical(spacing: 2) { title; subtitle }.hexpand()
                ends
            }
            Box.horizontal(spacing: 10) { elapsed; scale; length }
            Box.horizontal(spacing: 18) { back; playButton; forward }.halign(GTK_ALIGN_CENTER)
        }.margin(horizontal: 24, vertical: 16).css("video-controls")
        bar.valign(GTK_ALIGN_END)
        controls = Revealer(bar, transition: GTK_REVEALER_TRANSITION_TYPE_CROSSFADE)
        controls.valign(GTK_ALIGN_END)
        controls.isRevealed = true

        let error = Label("", "video-error").xalign(0.5)
        error.halign(GTK_ALIGN_CENTER).valign(GTK_ALIGN_CENTER).canTarget(false)
        let layers = Overlay(surface.root)
        layers.add(error)
        layers.add(controls)
        adw_window_set_content(window.cast(), layers.widget)
        layers.keep(self)
        reference.value = self

        // Clicking the picture shows or hides the controls; a double click is full screen.
        surface.root.onClick { reference.value?.toggleControls() }
        let doubleClick = gtk_gesture_click_new()!
        Signal.connect(doubleClick, "pressed", press: { count, _, _ in
            guard count == 2, let view = reference.value else { return }
            view.setFullScreen(!view.isFullScreen)
        })
        gtk_widget_add_controller(surface.root.widget, doubleClick.cast())

        // Only when playing changes: this runs four times a second, and rescheduling the
        // hide on every run would put it off for ever.
        var lastPlaying: Bool?
        scale.onUserChange { value in
            guard let view = reference.value else { return }
            view.dragging = true
            elapsed.text = Int(value).asDuration
            view.seekSoon(to: value)
        }
        layers.observe {
            let video = app.video
            let progress = video.progress
            let playing = watching == nil ? app.player.isPlaying : progress.isPlaying
            playButton.icon = playing ? "media-playback-pause-symbolic" : "media-playback-start-symbolic"
            title.text = watching?.title ?? app.player.currentSong?.title ?? video.current?.title ?? ""
            subtitle.text = watching?.channel ?? app.player.currentSong?.artist ?? ""
            length.text = Int(progress.duration).asDuration
            if !(reference.value?.dragging ?? false) {
                gtk_range_set_range(scale.widget.cast(), 0, max(progress.duration, 1))
                scale.value = progress.elapsed
                elapsed.text = Int(progress.elapsed).asDuration
            }
            error.text = watching != nil ? (video.watchError.map { "This video won't play.\n\($0)" } ?? "") : ""
            error.isVisible = !error.text.isEmpty
            if playing != lastPlaying {
                lastPlaying = playing
                if playing { reference.value?.scheduleHide() } else { reference.value?.showControls() }
            }
        }
        // The song's video gave way to its track: nothing left to show here.
        layers.observe {
            if watching == nil, !app.video.isStandingIn { DispatchQueue.main.async { reference.value?.close() } }
            if let watching, app.video.watching?.id != watching.id { DispatchQueue.main.async { reference.value?.close() } }
        }

        let keys = gtk_event_controller_key_new()!
        // Before the focused widget: space on a focused button would press it rather than
        // play or pause.
        gtk_event_controller_set_propagation_phase(keys, GTK_PHASE_CAPTURE)
        Signal.connect(keys, "key-pressed", key: { keyval, _, _ in
            guard let view = reference.value else { return false }
            switch Int32(keyval) {
            case GDK_KEY_space, GDK_KEY_k:
                view.togglePlay()
            case GDK_KEY_Escape:
                view.close()
            case GDK_KEY_f, GDK_KEY_F11:
                view.setFullScreen(!view.isFullScreen)
            case GDK_KEY_Left:
                view.seekBy(-5)
            case GDK_KEY_Right:
                view.seekBy(5)
            default:
                return false
            }
            view.showControls()
            return true
        })
        gtk_widget_add_controller(window, keys)
        // Out of full screen some other way -- the window manager's key or menu -- is the
        // same as Escape: back into the app, not into a small window.
        Signal.connect(window, "notify::fullscreened", pointer: { _ in
            guard let view = reference.value else { return }
            let now = gtk_window_is_fullscreen(view.window.cast()) != 0
            if view.wasFullScreen, !now {
                view.close()
                return
            }
            view.wasFullScreen = now
        })
        Signal.connectHandled(window, "close-request") {
            reference.value?.closed()
            return false
        }
    }

    private func togglePlay() {
        if watching == nil { app.player.togglePlayPause() } else { app.video.togglePlayPause() }
    }

    private func seekBy(_ seconds: Double) {
        if watching == nil {
            app.player.skip(by: seconds)
        } else {
            app.video.skip(by: seconds)
        }
    }

    private var seekTask: Task<Void, Never>?

    /// The scale reports every step of a drag; the video is asked to seek once it rests.
    private func seekSoon(to seconds: Double) {
        seekTask?.cancel()
        seekTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard let self, !Task.isCancelled else { return }
            if watching == nil { app.player.seek(to: seconds) } else { app.video.seek(to: seconds) }
            dragging = false
        }
    }

    private func setFullScreen(_ on: Bool) {
        guard on else {
            close()
            return
        }
        isFullScreen = true
        gtk_window_fullscreen(window.cast())
        showControls()
    }

    private func toggleControls() {
        if controls.isRevealed {
            hideTask?.cancel()
            controls.isRevealed = false
        } else {
            showControls()
        }
    }

    private func showControls() {
        controls.isRevealed = true
        scheduleHide()
    }

    /// Out of the way three seconds after the last touch, while it plays full screen.
    private func scheduleHide() {
        hideTask?.cancel()
        guard isFullScreen else { return }
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled, isFullScreen, !dragging else { return }
            let playing = watching == nil ? app.player.isPlaying : app.video.progress.isPlaying
            if playing { controls.isRevealed = false }
        }
    }

    private func close() {
        gtk_window_close(window.cast())
    }

    /// The window is going: a watched video ends, and the music picks up again.
    private func closed() {
        hideTask?.cancel()
        seekTask?.cancel()
        if Self.open === self { Self.open = nil }
        if let watching, app.video.watching?.id == watching.id { app.video.stopWatching() }
    }
}

/// Search's YouTube side: music videos and songs the library does not have. A result plays
/// in the video window; the add button gets it, lossless, through the Soulseek pipeline.
@MainActor
enum YouTubeResults {
    static func make(_ env: Env, query: String) -> Widget {
        let app = env.app
        guard app.video.isAvailable else {
            return StatusPage(
                icon: "video-x-generic-symbolic",
                title: "YouTube Needs the Sonic Service",
                description: "Videos come through the service on the server. It isn't answering right now."
            )
        }
        guard !query.isEmpty else {
            return StatusPage(
                icon: "video-x-generic-symbolic",
                title: "Search YouTube",
                description: "Music videos, and songs that aren't in your library yet. Play one, or add it to the library."
            )
        }
        let holder = Bin(Spinner().size(32).halign(GTK_ALIGN_CENTER).valign(GTK_ALIGN_START).margin(48))
        let alive = holder.liveness
        Task { @MainActor in
            let found = await app.video.search(query)
            guard alive.isAlive else { return }
            guard let found else {
                holder.child = StatusPage(
                    icon: "network-offline-symbolic",
                    title: "Can’t Reach YouTube",
                    description: "The search didn't go through. Try again in a moment."
                )
                return
            }
            guard !found.isEmpty else {
                holder.child = StatusPage(icon: "system-search-symbolic", title: "No Results",
                                          description: "YouTube has nothing for “\(query)”.")
                return
            }
            let list = Box.vertical(spacing: 2)
            for video in found {
                let add = Button(icon: "list-add-symbolic", "flat", "circular") {
                    app.recentSearches.record(query)
                    AddVideoToLibrary.ask(app, video, toast: env.toast)
                }
                add.tooltip("Add to Library…")
                let row = VideoRow.make(app, video, suffix: add) {
                    app.recentSearches.record(query)
                    watch(env, video)
                }
                row.contextMenu {
                    Menu([[
                        .action("Play Video") { watch(env, video) },
                        .action("Add to Library…") { AddVideoToLibrary.ask(app, video, toast: env.toast) },
                    ]])
                }
                list.append(row)
            }
            holder.child = list
        }
        return holder
    }

    static func watch(_ env: Env, _ video: VideoClient.Video) {
        env.app.video.watch(video)
        VideoWindow.present(env.app, watching: video, toast: env.toast)
    }
}
