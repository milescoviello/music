import CoreImage
import SwiftUI

enum PlayerMode: String, CaseIterable {
    case artwork, queue, lyrics, visualizer
}

struct NowPlayingView: View {
    @Environment(AppState.self) private var appState
    @Environment(PlayerSettings.self) private var playerSettings
    @Environment(RemotePlayers.self) private var remotes
    /// Called instead of `dismiss()`: this is no longer a modal, it is a layer drawn
    /// above the library, so closing it is the presenter's business.
    var onDismiss: () -> Void = {}

    @State private var mode: PlayerMode = .artwork
    /// Written by a sideways swipe over the visualiser; `VisualizerView` reads the same key.
    @AppStorage(VisualizerProgram.storageKey) private var visualizerName = VisualizerProgram.defaultName
    @State private var drag = DismissDrag()
    @State private var similarTo: Song?
    @State private var showsVisualizerPicker = false
    @Namespace private var modeNamespace

    private var player: PlaybackController { appState.player }

    private var keepAwake: Binding<Bool> {
        Binding(
            get: { appState.screenAwake.isEnabled },
            set: { appState.screenAwake.isEnabled = $0 }
        )
    }

    var body: some View {
        // Its own stack: without one, the artist name and the menu's "Go to Album" are
        // links with nowhere to push, which is to say dead. Browsing from inside the
        // player is also what Plexamp does.
        // The offset belongs out here, on the outermost layer.
        //
        // Applied inside the stack it moved only the *content*: the navigation stack's
        // own surface stayed exactly where it was and went on painting an opaque
        // background, so pulling the player down revealed a black wall rather than the
        // library. Whatever layer is opaque has to be the layer that moves.
        DismissOffset(drag: drag) {
            NavigationStack {
                playerBody
                    .toolbar(.hidden, for: .navigationBar)
                    .musicDestinations()
            }
        }
        .onAppear { drag.offset = 0 }
        .sheet(item: $similarTo) { song in
            SimilarTracksView(song: song)
        }
        .sheet(isPresented: $showsVisualizerPicker) {
            // Choosing one from the artwork shows it, as in Plexamp.
            VisualizerPicker(onSelect: { mode = .visualizer })
        }
    }

    private var playerBody: some View {
        VStack(spacing: 0) {
            topBar

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let song = player.currentSong {
                // The title block is its own drag surface in *every* mode, including
                // queue and lyrics. It is the natural place to grab from and it never
                // scrolls, so nothing competes for the gesture here.
                VStack(spacing: 0) {
                    metadata(song)
                    PlayerDetailLine(song: song)
                }
                .contentShape(Rectangle())
                .gesture(dismissDrag)

                // Artwork mode only, and deliberately its own row *outside*
                // `PlayerSeekBar`: that view exists to contain the 4 Hz elapsed tick, and
                // putting the stars inside it would repaint them four times a second.
                // Rating happens while listening, which is why it belongs here and not
                // only in a list's context menu.
                if mode == .artwork {
                    RatingStars(songID: song.id, serverRating: song.userRating)
                        .padding(.top, 6)
                }

                resumeStrip
                PlayerSeekBar()
                transport
                volumeRow
                bottomRow
            }
        }
        // `contentShape` is the fix for "it only works on the album art": empty layout
        // space in a stack is not hit-testable, so a drag starting to the right of the
        // title was landing on nothing at all. The artwork worked only because an image
        // is opaque. This makes the whole screen a drag surface.
        .contentShape(Rectangle())
        // Masked off in the scrolling modes, where the queue and lyrics own the vertical
        // pan; the top bar and the title block carry the gesture there instead.
        .gesture(dismissDrag, including: isScrollingMode ? .subviews : .all)
        .background(alignment: .top) { backdrop }
    }

    // MARK: - Dismissal

    /// The dismiss gesture, entirely hand-rolled.
    ///
    /// `fullScreenCover` had no interactive dismiss, and a `sheet` cannot go edge to edge
    /// on a screen that is mostly artwork. It is now neither: the player is a layer above
    /// the library, which is what lets the library show through as it is pulled down --
    /// a modal removes the presenting view from the hierarchy entirely, so there was
    /// literally nothing behind it to see.
    private var dismissDrag: some Gesture {
        // `.global` is the whole fix, and the reason this kept feeling broken no matter
        // what else was tuned: the gesture is attached to the same view that
        // `DismissOffset` moves, and a `DragGesture` measures translation in its
        // own **local** space. So the finger moved the view, the view moved the space the
        // finger was being measured in, and the next reading was taken against a moved
        // ruler -- a feedback loop that reads as jitter. A global space does not move with
        // the thing being dragged.
        DragGesture(minimumDistance: 18, coordinateSpace: .global)
            .onChanged { value in
                // Vertical drags only. A sideways swipe is not a dismissal, and tracking
                // it made the screen twitch whenever a horizontal gesture began.
                guard abs(value.translation.height) > abs(value.translation.width) else {
                    return
                }
                // Downward only: allowing up would let the screen be pulled off the top.
                drag.offset = max(0, value.translation.height)
            }
            .onEnded { value in
                // Over the visualiser, a mostly sideways swipe is Plexamp's next or
                // previous visualiser. Read here rather than by a drag of the visualiser's
                // own, which would take the downward pull from this one.
                let dx = value.translation.width
                if mode == .visualizer, abs(dx) > abs(value.translation.height), abs(dx) >= 50 {
                    let program = VisualizerProgram.named(visualizerName)
                    visualizerName = (dx < 0 ? program.next : program.previous).name
                    // A swipe can start downward enough to have moved the player.
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                        drag.offset = 0
                    }
                    return
                }

                // Distance *or* speed, so a quick flick works without travelling far.
                let isFarEnough = value.translation.height > 130
                let isFastEnough = value.predictedEndTranslation.height > 320

                if isFarEnough || isFastEnough {
                    onDismiss()
                } else {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                        drag.offset = 0
                    }
                }
            }
    }

    /// A visible close button as well as the gesture: the previous version had only a
    /// 5pt capsule that happened to be tappable, which is not an affordance.
    /// Queue and lyrics own the vertical scroll, so a full-screen drag would fight
    /// them. The visualiser and artwork do not scroll, so there it can cover everything.
    private var isScrollingMode: Bool {
        mode == .queue || mode == .lyrics
    }

    private var topBar: some View {
        HStack(spacing: Metrics.itemSpacing) {
            Button {
                onDismiss()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(minWidth: Metrics.minimumTouchTarget, minHeight: Metrics.minimumTouchTarget)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Close player")

            VStack(spacing: 1) {
                Text("Playing From")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.5))
                QueueSourceText()
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)

            if let song = player.currentSong {
                Menu {
                    // No rating rows here: the five stars are already on screen a few
                    // points below, and a heart is what marks a favourite now — one
                    // meaning per glyph.
                    // `showsNavigation: false` because the menu's own Go to Album/Artist
                    // are `NavigationLink`s, which push *inside* the player — the dead end
                    // this screen's own jumps avoid. Replaced below with jumps.
                    SongMenu(song: song, showsNavigation: false, showsRating: false)

                    if let albumId = song.albumId, let album = song.album {
                        Button("Go to Album", systemImage: "square.stack") {
                            appState.navigator.open(.album(AlbumRef(
                                id: albumId, name: album,
                                artist: song.artist, coverArt: song.coverArt
                            )))
                        }
                    }

                    if let artistId = song.artistId, let artist = song.artist {
                        Button("Go to Artist", systemImage: "music.mic") {
                            appState.navigator.open(
                                .artist(ArtistRef(id: artistId, name: artist))
                            )
                        }
                    }

                    Button("Show Similar Tracks", systemImage: "wand.and.stars") {
                        similarTo = song
                    }
                    Button("Sonic Adventure…", systemImage: Station.adventure(fromID: "", toID: "").symbol) {
                        appState.navigator.open(.sonicAdventure(song))
                    }
                    Divider()

                    GuestDJMenu()
                    PlaybackSpeedMenu()
                    // Next to the sleep timer deliberately: one puts the music to sleep,
                    // the other stops the screen doing it, and they get reached for in the
                    // same moments — lyrics propped up on a desk, or a long mix.
                    Toggle(isOn: keepAwake) {
                        Label("Keep Screen On", systemImage: "sun.max")
                    }

                    SleepTimerMenu()

                    Button("Select Visualizer…", systemImage: "waveform") {
                        showsVisualizerPicker = true
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(
                            width: Metrics.minimumTouchTarget,
                            height: Metrics.minimumTouchTarget
                        )
                        .contentShape(Rectangle())
                }
            } else {
                Spacer().frame(width: Metrics.minimumTouchTarget)
            }
        }
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .gesture(dismissDrag, including: isScrollingMode ? .all : .subviews)
    }

    /// Blurred artwork behind everything: the only place colour comes from content.
    ///
    /// `drawingGroup()` is not decoration. A 60pt blur over a full-screen image was
    /// being recomputed on every frame of the dismiss drag, which is what made the
    /// gesture stutter. Flattened into one texture, moving it is nearly free.
    @ViewBuilder
    private var backdrop: some View {
        switch playerSettings.background {
        case .ultrablur:
            ArtworkImage(id: player.currentSong?.coverArt, size: .full, cornerRadius: 0)
                // Fills whatever it is given and crops the rest, which is all a backdrop has
                // to do. No `aspectRatio`: that asks the art how big it wants to be, and the
                // answer for a non-square cover is "bigger than this".
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .blur(radius: 60, opaque: true)
                .overlay(.black.opacity(0.45))
                .drawingGroup()
                .ignoresSafeArea()
        case .smooth, .flat:
            // Plexamp's other two: the artwork's own colour, as a gradient or flat.
            ArtworkColorBackdrop(coverArt: player.currentSong?.coverArt, isGradient: playerSettings.background == .smooth)
                .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private var content: some View {
        ZStack {
            switch mode {
            case .artwork:
                ArtworkImage(
                    id: player.currentSong?.coverArt,
                    size: .full,
                    cornerRadius: Metrics.radiusPlayer
                )
                .aspectRatio(1, contentMode: .fit)
                .padding(.horizontal, 24)
                .shadow(radius: 24, y: 12)
                // One small motion cue that makes the screen feel alive.
                .scaleEffect(player.isPlaying ? 1 : 0.86)
                .animation(.spring(duration: 0.35), value: player.isPlaying)
                .matchedGeometryEffect(id: "artwork", in: modeNamespace)
                // Plexamp's artwork is the visualiser's other side: a tap turns it over,
                // a long press picks which one.
                .onTapGesture { mode = .visualizer }
                .onLongPressGesture { showsVisualizerPicker = true }

            case .queue:
                QueueView()

            case .lyrics:
                if let song = player.currentSong {
                    LyricsView(song: song)
                }

            case .visualizer:
                VisualizerView(
                    isPaused: drag.isMoved,
                    onTap: { mode = .artwork },
                    onLongPress: { showsVisualizerPicker = true }
                )
            }
        }
        .animation(.easeInOut(duration: 0.25), value: mode)
    }

    private func metadata(_ song: Song) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(.title3.weight(.bold))
                    .lineLimit(1)

                // Tappable, because "who is this" is the most common next question and
                // the menu is two taps away.
                //
                // A **jump**, not a push: pushing inside the player leaves you on an
                // artist page with no tab bar and no player bar, because the player is a
                // layer above both. `Navigator` closes the player and opens it in Library
                // instead, where the chrome is.
                if let artist = song.artist {
                    if let artistId = song.artistId {
                        Button {
                            appState.navigator.open(
                                .artist(ArtistRef(id: artistId, name: artist))
                            )
                        } label: {
                            artistLabel(artist)
                        }
                        .buttonStyle(.plain)
                    } else {
                        artistLabel(artist)
                    }
                }

                // The album, on screen rather than two taps into a menu — "what record is
                // this from" is the other question this screen gets asked.
                if let album = song.album {
                    if let albumId = song.albumId {
                        Button {
                            appState.navigator.open(.album(AlbumRef(
                                id: albumId,
                                name: album,
                                artist: song.artist,
                                coverArt: song.coverArt
                            )))
                        } label: {
                            albumLabel(album, isLink: true)
                        }
                        .buttonStyle(.plain)
                    } else {
                        albumLabel(album, isLink: false)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            FavoriteButton(id: song.id, kind: .song, serverValue: song.isFavorite)
                .font(.title3)
                .frame(width: 36, height: 36)
        }
        .padding(.horizontal, 24)
        .padding(.top, Metrics.itemSpacing)
        .contentShape(Rectangle())
    }

    private func artistLabel(_ artist: String) -> some View {
        Text(artist)
            .font(.title3)
            .foregroundStyle(.white.opacity(0.7))
            .lineLimit(1)
    }

    /// Quieter than the artist and marked with a chevron when it goes somewhere, so the
    /// two lines do not read as equally important.
    private func albumLabel(_ album: String, isLink: Bool) -> some View {
        HStack(spacing: 4) {
            Text(album)
                .font(.subheadline)
                .lineLimit(1)
            if isLink {
                Image(systemName: "chevron.right")
                    .font(.caption2)
            }
        }
        .foregroundStyle(.white.opacity(0.5))
    }

    /// Shown for a few seconds when playback started part-way through a long track.
    ///
    /// A silent auto-seek with no way back is the failure mode this exists to avoid: the
    /// strip says where it resumed from and offers the undo, then gets out of the way.
    @ViewBuilder
    private var resumeStrip: some View {
        if let notice = appState.player.resumeNotice,
           notice.songID == appState.player.currentSong?.id {
            HStack(spacing: 10) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.caption)
                Text("Resumed from \(Int(notice.seconds).asDuration)")
                    .font(.caption)
                Button("Start over") {
                    appState.player.startOver()
                }
                .font(.caption.weight(.semibold))
            }
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.top, 8)
            .transition(.opacity)
            .task(id: notice) {
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.3)) {
                    appState.player.resumeNotice = nil
                }
            }
        }
    }

    private var transport: some View {
        let showsSkip = playerSettings.showsSkipButtons

        return HStack(spacing: showsSkip ? 16 : 28) {
            ShuffleButton()

            if showsSkip {
                Button { player.skip(by: -Double(playerSettings.skipBackSeconds)) } label: {
                    Image(systemName: "gobackward.\(playerSettings.skipBackSeconds)").font(.title3)
                }
                .accessibilityLabel("Back \(playerSettings.skipBackSeconds) seconds")
            }

            Button { player.previous() } label: {
                Image(systemName: "backward.fill").font(.title2)
            }
            .accessibilityLabel("Previous track")

            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 56))
            }
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

            Button { player.next() } label: {
                Image(systemName: "forward.fill").font(.title2)
            }
            .accessibilityLabel("Next track")

            if showsSkip {
                Button { player.skip(by: Double(playerSettings.skipForwardSeconds)) } label: {
                    Image(systemName: "goforward.\(playerSettings.skipForwardSeconds)").font(.title3)
                }
                .accessibilityLabel("Forward \(playerSettings.skipForwardSeconds) seconds")
            }

            RepeatButton()
        }
        .foregroundStyle(.white)
        .padding(.top, Metrics.itemSpacing)
    }

    /// The system slider, flanked by the usual two icons so it reads as volume rather
    /// than a second progress bar. While a computer is being played to, that computer's
    /// volume instead, and where the music is.
    private var volumeRow: some View {
        Group {
            if let session = remotes.session {
                RemoteVolumeRow(session: session)
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "speaker.fill")
                    SystemVolumeSlider()
                    Image(systemName: "speaker.wave.3.fill")
                }
            }
        }
        .font(.caption2)
        .foregroundStyle(.white.opacity(0.5))
        .padding(.horizontal, 24)
        .padding(.top, Metrics.itemSpacing)
    }

    private var bottomRow: some View {
        HStack {
            modeButton(.lyrics, "quote.bubble")
            Spacer()
            modeButton(.artwork, "photo")
            Spacer()
            modeButton(.visualizer, "waveform")
            Spacer()
            modeButton(.queue, "list.bullet")
            Spacer()
            RemotePlayerButton()
            Spacer()
            // Fixed, not a minimum: this is a fixed-size glyph rather than text, and a
            // minimum let it grow to fill the row. Centred in a touch-target-sized box.
            AudioRoutePicker()
                .frame(width: 22, height: 22)
                .frame(width: Metrics.minimumTouchTarget, height: Metrics.minimumTouchTarget)
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 4)
    }

    /// Selection is shown by tint and weight, not by swapping in a `.fill` variant.
    /// Appending ".fill" was a guess that does not hold: `waveform.fill` and
    /// `list.bullet.fill` are not real symbols, and an unknown name renders as blank.
    private func modeButton(_ target: PlayerMode, _ symbol: String) -> some View {
        let isSelected = mode == target

        return Button {
            mode = isSelected ? .artwork : target
        } label: {
            Image(systemName: symbol)
                .font(.title3.weight(isSelected ? .bold : .regular))
                .foregroundStyle(isSelected ? Color.appTint : .white.opacity(0.6))
                .frame(minWidth: Metrics.minimumTouchTarget, minHeight: Metrics.minimumTouchTarget)
        }
        .accessibilityLabel(String(describing: target).capitalized)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

// The three things the player shows that are about the queue rather than the track:
// views of their own, so that reading `queue` for them makes a queue edit redraw them and
// not the whole player.

/// Where the queue came from: "Kid A", or just "Queue".
private struct QueueSourceText: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let described = appState.player.queue.sourceDescription
        Text(described.isEmpty ? "Queue" : described)
    }
}

private struct ShuffleButton: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let player = appState.player
        Button { player.toggleShuffle() } label: {
            Image(systemName: "shuffle")
                .foregroundStyle(player.queue.isShuffled ? Color.appTint : .white.opacity(0.7))
        }
        .accessibilityLabel(player.queue.isShuffled ? "Shuffle on" : "Shuffle off")
    }
}

private struct RepeatButton: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let player = appState.player
        Button { player.cycleRepeat() } label: {
            Image(systemName: player.queue.repeatMode.symbol)
                .foregroundStyle(
                    player.queue.repeatMode == .off ? .white.opacity(0.7) : Color.appTint
                )
        }
        .accessibilityLabel("Repeat: \(player.queue.repeatMode.rawValue)")
    }
}

/// The quiet line Plexamp gets right: what you are actually hearing, and where you are
/// in the queue. Every part is omitted when unknown rather than shown as a placeholder.
///
/// Its own view because of everything it reads: the downloads catalog, the stream cache,
/// the network, the sleep timer, the Guest DJ. Inside the player's body, a download
/// finishing anywhere in the library, or a file landing in the cache, re-ran the whole
/// player; here it re-runs one line.
private struct PlayerDetailLine: View {
    @Environment(AppState.self) private var appState
    @Environment(SleepTimer.self) private var sleepTimer
    @Environment(DownloadCenter.self) private var downloads
    @Environment(GuestDJService.self) private var guestDJ

    let song: Song

    private var player: PlaybackController { appState.player }

    var body: some View {
        HStack(spacing: 6) {
            if downloads.isDownloaded(song.id) {
                Label("Downloaded", systemImage: "arrow.down.circle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(Color.appTint)
            }

            Text(qualityText(song))

            if let count = song.playCount, count > 0 {
                Text("·")
                Text("\(count) \(count == 1 ? "play" : "plays")")
            }

            if player.queue.order.count > 1 {
                Text("·")
                Text("\(player.queue.position + 1) of \(player.queue.order.count)")
                    .monospacedDigit()
            }

            if let dj = guestDJ.dj {
                Text("·")
                Label(dj.name, systemImage: "sparkles")
                    .foregroundStyle(Color.appTint)
            }

            if player.speed != 1 {
                Text("·")
                Text(String(format: "%.1f×", player.speed))
                    .monospacedDigit()
                    .foregroundStyle(Color.appTint)
            }

            if let label = sleepTimer.label {
                Text("·")
                Label(label, systemImage: "moon.fill")
                    .foregroundStyle(Color.appTint)
            }

            if appState.screenAwake.isEnabled {
                Text("·")
                Label("Screen on", systemImage: "sun.max.fill")
                    .foregroundStyle(Color.appTint)
            }

            Spacer(minLength: 0)
        }
        .font(.caption2)
        .foregroundStyle(.white.opacity(0.55))
        .padding(.horizontal, 24)
        .padding(.top, 5)
    }

    /// "FLAC 24/96", "MP3 320 kbps". For lossless the depth and rate are the useful
    /// numbers; the bitrate is variable and the reported figure is only an average, so
    /// quoting it would look precise while meaning little.
    private func qualityText(_ song: Song) -> String {
        // What is actually being heard: a stream converted to fit this network's quality
        // setting says so, rather than quoting the file on the server.
        if !downloads.isDownloaded(song.id) {
            let variant = appState.streaming.policy.variant(for: song, on: appState.reachability.network)
            if case let .mp3(kbps) = variant,
               // The index, not `file(for:)`: that one marks the entry used, and a view
               // body that writes what it reads redraws forever.
               appState.streamCache.index.entry(for: song.id, satisfying: .original) == nil {
                return "MP3 · \(kbps) kbps · converted"
            }
        }

        var parts: [String] = []
        if let suffix = song.suffix { parts.append(suffix.uppercased()) }

        let isLossless = ["flac", "wav", "aiff", "aif", "alac"]
            .contains(song.suffix?.lowercased() ?? "")

        if isLossless {
            if let depth = song.bitDepth, let rate = song.samplingRate, rate > 0 {
                parts.append("\(depth)/\(kilohertz(rate))")
            } else if let rate = song.samplingRate, rate > 0 {
                parts.append("\(kilohertz(rate)) kHz")
            }
        } else if let rate = song.bitRate, rate > 0 {
            parts.append("\(rate) kbps")
        }

        if song.channelCount == 1 { parts.append("mono") }

        return parts.isEmpty ? "Streaming" : parts.joined(separator: " · ")
    }

    /// 44100 reads as 44.1, 48000 as 48 -- no trailing ".0".
    private func kilohertz(_ hertz: Int) -> String {
        let value = Double(hertz) / 1000
        return value == value.rounded()
            ? String(Int(value))
            : String(format: "%.1f", value)
    }
}

/// How far the player has been pulled down. An object rather than `@State` on the player,
/// so that only `DismissOffset` reads `offset`: as state on the player it was read by the
/// player's body, which then ran on every frame of the drag — the whole screen rebuilt
/// sixty or a hundred and twenty times a second to move it.
@MainActor
@Observable
private final class DismissDrag {
    var offset: CGFloat = 0 {
        didSet {
            // Written only when it flips, so the player's body, which reads this, runs at
            // the start and end of a drag and not in between.
            if (offset != 0) != isMoved { isMoved = offset != 0 }
        }
    }

    /// Whether the player is off its resting place at all.
    private(set) var isMoved = false
}

/// Moves the player with the drag. The content is built by the player and only offset
/// here, so a change of offset re-runs this body and nothing inside it.
private struct DismissOffset<Content: View>: View {
    let drag: DismissDrag
    @ViewBuilder let content: Content

    var body: some View {
        content.offset(y: drag.offset)
    }
}

/// Its own view on purpose. It reads `elapsed`, which ticks four times a second, and
/// under `@Observable` that invalidates whatever view read it -- so inside the player's
/// body it was re-rendering the entire screen, blurred backdrop included, 4x/second.
/// Scoped here, the tick repaints a seekbar and two labels.
private struct PlayerSeekBar: View {
    @Environment(AppState.self) private var appState
    @Environment(PlayerSettings.self) private var playerSettings

    @State private var scrubValue: Double?

    private var player: PlaybackController { appState.player }

    /// A stream with no determinable length -- a server-side transcode is chunked, so
    /// there is no duration and no seeking either.
    private var hasKnownDuration: Bool { player.duration > 0 }

    private var position: Double { scrubValue ?? player.elapsed }

    /// The track's loudness as Plexamp's bar heights, in points: from the sonic service,
    /// or measured here when the service has not analysed it. Empty until one of them has
    /// it. Read without touching the disk or the network: the `.task` below loads it.
    private var heights: [Float] {
        guard let id = player.currentSong?.id, let levels = appState.seekbarLevels.levels(for: id) else { return [] }
        return SeekbarShape.interpolate(SeekbarShape.heights(fromLevels: levels), to: LoudnessSeekBar.points)
    }

    var body: some View {
        VStack(spacing: 2) {
            if playerSettings.seekbarStyle == .line {
                Slider(
                    value: Binding(
                        get: { position },
                        set: { scrubValue = $0 }
                    ),
                    in: 0...max(player.duration, 1),
                    onEditingChanged: { editing in
                        // Commit on release rather than seeking continuously.
                        guard !editing else { return }
                        if let value = scrubValue { player.seek(to: value) }
                        // Cleared unconditionally. While it was only cleared alongside a
                        // committed seek, a drag that ended without one left the slider
                        // showing a held value and it stopped following the music entirely
                        // until the next successful scrub.
                        scrubValue = nil
                    }
                )
                // Disabled rather than hidden: the row keeps its height, so the controls
                // below do not jump when a duration arrives a moment after playback starts.
                .disabled(!hasKnownDuration)
                .opacity(hasKnownDuration ? 1 : 0.35)
            } else {
                LoudnessSeekBar(
                    heights: heights,
                    trackID: player.currentSong?.id,
                    progress: hasKnownDuration ? min(1, max(0, position / player.duration)) : 0,
                    isBars: playerSettings.seekbarStyle == .bars,
                    onScrub: { scrubValue = $0 * player.duration },
                    onCommit: {
                        player.seek(to: $0 * player.duration)
                        scrubValue = nil
                    },
                    onCancel: { scrubValue = nil }
                )
                .allowsHitTesting(hasKnownDuration)
                .opacity(hasKnownDuration ? 1 : 0.35)
            }

            HStack {
                Text(Int(position).asDuration)
                Spacer()
                // Rather than "0:00", which reads as a bug -- and was one.
                Text(hasKnownDuration ? Int(max(player.duration - position, 0)).asDuration : "--:--")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.6))
        }
        .padding(.horizontal, 24)
        .padding(.top, 6)
        // A track change during a scrub would otherwise leave the thumb pinned at a
        // position in the *previous* song.
        .onChange(of: player.currentSong?.id) { scrubValue = nil }
        // The style too, so switching from Line to a shape fetches the shape at once.
        .task(id: [player.currentSong?.id, playerSettings.seekbarStyle.rawValue]) {
            guard let id = player.currentSong?.id else { return }
            _ = appState.shapes.shape(for: id)
            if playerSettings.seekbarStyle != .line { appState.seekbarLevels.request([id]) }
        }
    }
}

/// Plexamp's Smooth and Bars seekbars: the track's loudness, start to end, so you can see
/// the part you are about to skip to. Tinted up to where it has played, with a thin
/// playhead there. Tap anywhere to go there, or drag to scrub; the seek happens on
/// release, as with the slider.
///
/// Until the track's shape is known it is a flat line that works the same, and when the
/// shape arrives, or the track changes, it grows up out of the line.
private struct LoudnessSeekBar: View {
    /// Plexamp's heights, in points, `SeekbarShape.maximumHeight` at the loudest. Empty
    /// while the shape is not known.
    let heights: [Float]
    let trackID: String?
    let progress: Double
    let isBars: Bool
    let onScrub: (Double) -> Void
    let onCommit: (Double) -> Void
    let onCancel: () -> Void

    @GestureState private var isDragging = false

    /// Plexamp draws its seekbar from 128 points, whatever the levels came as.
    static let points = 128
    private static let height = CGFloat(SeekbarShape.maximumHeight)
    /// So silence and a shape not known yet still show where the bar runs.
    private static let minimumHeight: CGFloat = 2
    /// The bar is shorter than a finger; this much above and below it still catches one.
    private static let touchSlop: CGFloat = 6

    /// Changes when there is a new shape to grow: another track, or the first for this one.
    private var revealKey: String? { heights.isEmpty ? nil : trackID }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            outline
                .frame(height: Self.height)
                .overlay(alignment: .leading) { playhead(in: width) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(scrub(in: width))
        }
        .frame(height: Self.height + 2 * Self.touchSlop)
        // A drag the system cancels never reaches `onEnded`; without this the bar would
        // stay at the scrubbed position and stop following the music.
        .onChange(of: isDragging) { _, dragging in
            if !dragging { onCancel() }
        }
        .accessibilityElement()
        .accessibilityLabel("Position")
        .accessibilityValue("\(Int(progress * 100)) percent")
        .accessibilityAdjustableAction { direction in
            let step = direction == .increment ? 0.05 : -0.05
            onCommit(min(1, max(0, progress + step)))
        }
    }

    private var outline: some View {
        Canvas { context, size in
            let shape = isBars ? bars(in: size) : curve(in: size)
            context.fill(shape, with: .color(.white.opacity(0.25)))
            var played = context
            played.clip(to: Path(CGRect(x: 0, y: 0, width: size.width * progress, height: size.height)))
            played.fill(shape, with: .color(Color.appTint))
        }
        .keyframeAnimator(initialValue: CGFloat(1), trigger: revealKey) { content, scale in
            content.scaleEffect(x: 1, y: scale, anchor: .bottom)
        } keyframes: { _ in
            MoveKeyframe(0)
            SpringKeyframe(1, duration: 0.6, spring: .smooth)
        }
    }

    private func playhead(in width: CGFloat) -> some View {
        let thickness: CGFloat = isDragging ? 3 : 2
        return Capsule()
            .fill(.white)
            .frame(width: thickness, height: Self.height + 4)
            .offset(x: min(max(width * progress - thickness / 2, 0), max(width - thickness, 0)))
            .animation(.easeOut(duration: 0.15), value: isDragging)
    }

    private func scrub(in width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($isDragging) { _, dragging, _ in dragging = true }
            .onChanged { onScrub(fraction($0.location.x, width)) }
            .onEnded { value in
                // A swipe down that happened to start on the bar was meant to close the
                // player, not to seek to wherever the finger left it.
                let down = value.translation.height
                if down > 60, down > 2 * abs(value.translation.width) {
                    onCancel()
                } else {
                    onCommit(fraction(value.location.x, width))
                }
            }
    }

    private func fraction(_ x: CGFloat, _ width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return Double(min(max(x / width, 0), 1))
    }

    /// The heights to draw across `count` points; flat while the shape is not known.
    private func values(_ count: Int) -> [CGFloat] {
        let source = heights.isEmpty ? [0] : heights
        let resampled = source.count == count ? source : SeekbarShape.interpolate(source, to: count)
        return resampled.map { max(Self.minimumHeight, CGFloat($0)) }
    }

    /// A bar per point, standing on the bottom edge; fewer only if the bar is too narrow
    /// for a bar every two and a half points.
    private func bars(in size: CGSize) -> Path {
        let count = max(1, min(heights.isEmpty ? Self.points : heights.count, Int(size.width / 2.5)))
        let slot = size.width / CGFloat(count)
        let barWidth = max(1, slot * 0.65)
        var path = Path()
        for (index, value) in values(count).enumerated() {
            let barHeight = min(value, size.height)
            path.addRoundedRect(
                in: CGRect(x: CGFloat(index) * slot + (slot - barWidth) / 2, y: size.height - barHeight,
                           width: barWidth, height: barHeight),
                cornerSize: CGSize(width: barWidth / 2, height: barWidth / 2),
                style: .continuous
            )
        }
        return path
    }

    /// A filled curve rising from the bottom edge through every point, smoothed through
    /// the midpoints between them.
    private func curve(in size: CGSize) -> Path {
        let heights = values(max(2, self.heights.count))
        let step = size.width / CGFloat(heights.count - 1)
        let points = heights.enumerated().map { index, value in
            CGPoint(x: CGFloat(index) * step, y: size.height - min(value, size.height))
        }
        var path = Path()
        path.move(to: CGPoint(x: 0, y: size.height))
        path.addLine(to: points[0])
        for index in 1..<points.count {
            let previous = points[index - 1], current = points[index]
            let middle = CGPoint(x: (previous.x + current.x) / 2, y: (previous.y + current.y) / 2)
            path.addQuadCurve(to: middle, control: previous)
        }
        path.addLine(to: points[points.count - 1])
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.closeSubpath()
        return path
    }
}

/// The Flat and Smooth player backgrounds: the artwork's average colour, darkened enough
/// for white text, either as it is or as a gradient into black.
private struct ArtworkColorBackdrop: View {
    @Environment(ArtworkStore.self) private var artwork

    let coverArt: String?
    let isGradient: Bool

    @State private var color: Color = Color(white: 0.12)

    var body: some View {
        Group {
            if isGradient {
                LinearGradient(colors: [color, color.opacity(0.55), .black], startPoint: .top, endPoint: .bottom)
            } else {
                color
            }
        }
        .animation(.easeInOut(duration: 0.6), value: color)
        .task(id: coverArt) {
            guard let image = await artwork.image(for: coverArt, size: .thumb) else { return }
            // Off the main thread: it makes a Core Image context and renders with it, once
            // per track, and on the main thread that landed just as the new track's screen
            // was being drawn.
            let average = await Task.detached(priority: .userInitiated) { image.averageColor }.value
            guard let average, !Task.isCancelled else { return }
            color = average
        }
    }
}

private extension UIImage {
    /// The mean colour, darkened to at most 45 % brightness so white text always reads.
    var averageColor: Color? {
        guard let input = CIImage(image: self) else { return nil }
        let extent = CIVector(x: input.extent.origin.x, y: input.extent.origin.y,
                              z: input.extent.size.width, w: input.extent.size.height)
        guard let filter = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: input, kCIInputExtentKey: extent]),
              let output = filter.outputImage
        else { return nil }

        var pixel = [UInt8](repeating: 0, count: 4)
        CIContext(options: [.workingColorSpace: NSNull()]).render(
            output, toBitmap: &pixel, rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil
        )
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        UIColor(red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255, blue: CGFloat(pixel[2]) / 255, alpha: 1)
            .getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return Color(hue: Double(hue), saturation: Double(saturation), brightness: Double(min(brightness, 0.45)))
    }
}

/// Lives in the player's overflow menu rather than in Settings: it is a thing you
/// reach for while already listening in bed, not something you configure.
///
/// Plexamp's choices, including End of Album — offered, as Plexamp offers it, only when
/// everything up next is from one album, which is when "the end of the album" means
/// something.
struct SleepTimerMenu: View {
    @Environment(SleepTimer.self) private var timer
    @Environment(AppState.self) private var appState

    private var albumPlaying: String? {
        let queue = appState.player.queue
        guard let album = queue.current?.albumId,
              queue.hasUpNext,
              // Only checked for a queue short enough to be one album.
              queue.upNextCount < 200,
              queue.upNext.allSatisfy({ $0.albumId == album })
        else { return nil }
        return album
    }

    var body: some View {
        Menu {
            if timer.isArmed {
                Button("Turn Off", systemImage: "moon.slash") {
                    timer.cancel()
                }
                Divider()
            }

            ForEach(SleepTimer.minuteOptions, id: \.self) { minutes in
                Button(minutes == 60 ? "1 Hour" : "\(minutes) Minutes") {
                    timer.arm(minutes: minutes)
                }
            }

            Button("End of Track", systemImage: "music.note") {
                timer.armEndOfTrack()
            }

            if let album = albumPlaying {
                Button("End of Album", systemImage: "square.stack") {
                    timer.armEndOfAlbum(albumID: album)
                }
            }
        } label: {
            Label(
                timer.label.map { "Sleep Timer — \($0)" } ?? "Sleep Timer",
                systemImage: timer.isArmed ? "moon.fill" : "moon"
            )
        }
    }
}

/// Plexamp's speed control: half to double speed in tenths, pitch kept. A submenu rather
/// than Plexamp's slider, because a menu cannot hold one.
struct PlaybackSpeedMenu: View {
    @Environment(AppState.self) private var appState

    private static let options: [Float] = stride(from: 5, through: 20, by: 1).map { Float($0) / 10 }

    var body: some View {
        let player = appState.player

        Menu {
            Picker("Playback Speed", selection: Binding(
                get: { player.speed },
                set: { player.setSpeed($0) }
            )) {
                ForEach(Self.options, id: \.self) { value in
                    Text(String(format: "%.1f×", value)).tag(value)
                }
            }
        } label: {
            Label(
                player.speed == 1 ? "Playback Speed" : String(format: "Playback Speed — %.1f×", player.speed),
                systemImage: "gauge.with.dots.needle.67percent"
            )
        }
    }
}

/// Plexamp's Guest DJ picker. Choosing one starts it on the track playing; choosing Off
/// takes its upcoming picks out of the queue with it.
struct GuestDJMenu: View {
    @Environment(GuestDJService.self) private var guestDJ

    var body: some View {
        Menu {
            Button {
                guestDJ.setDJ(nil)
            } label: {
                if guestDJ.dj == nil {
                    Label("Off", systemImage: "checkmark")
                } else {
                    Text("Off")
                }
            }

            ForEach(GuestDJ.allCases) { dj in
                Button {
                    guestDJ.setDJ(dj)
                } label: {
                    if guestDJ.dj == dj {
                        Label(dj.name, systemImage: "checkmark")
                    } else {
                        Text(dj.name)
                    }
                    Text(dj.summary)
                }
            }
        } label: {
            Label(
                guestDJ.dj.map { "Guest DJ — \($0.name)" } ?? "Guest DJ",
                systemImage: "sparkles"
            )
        }
    }
}
