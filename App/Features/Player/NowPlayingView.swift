import SwiftUI

enum PlayerMode: String, CaseIterable {
    case artwork, queue, lyrics, visualizer
}

struct NowPlayingView: View {
    @Environment(AppState.self) private var appState
    @Environment(SleepTimer.self) private var sleepTimer
    @Environment(DownloadCenter.self) private var downloads
    @Environment(PlayerSettings.self) private var playerSettings
    @Environment(GuestDJService.self) private var guestDJ
    /// Called instead of `dismiss()`: this is no longer a modal, it is a layer drawn
    /// above the library, so closing it is the presenter's business.
    var onDismiss: () -> Void = {}

    @State private var mode: PlayerMode = .artwork
    @State private var dragOffset: CGFloat = 0
    @State private var similarTo: Song?
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
        NavigationStack {
            playerBody
                .toolbar(.hidden, for: .navigationBar)
                .musicDestinations()
        }
        // The offset belongs out here, on the outermost layer.
        //
        // Applied inside the stack it moved only the *content*: the navigation stack's
        // own surface stayed exactly where it was and went on painting an opaque
        // background, so pulling the player down revealed a black wall rather than the
        // library. Whatever layer is opaque has to be the layer that moves.
        .offset(y: dragOffset)
        .onAppear { dragOffset = 0 }
        .sheet(item: $similarTo) { song in
            SimilarTracksView(song: song)
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
                    detailLine(song)
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
        // `.offset(y: dragOffset)` moves, and a `DragGesture` measures translation in its
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
                dragOffset = max(0, value.translation.height)
            }
            .onEnded { value in
                // Distance *or* speed, so a quick flick works without travelling far.
                let isFarEnough = value.translation.height > 130
                let isFastEnough = value.predictedEndTranslation.height > 320

                if isFarEnough || isFastEnough {
                    onDismiss()
                } else {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                        dragOffset = 0
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
                Text(source)
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

    private var source: String {
        let described = player.queue.sourceDescription
        return described.isEmpty ? "Queue" : described
    }

    /// Blurred artwork behind everything: the only place colour comes from content.
    ///
    /// `drawingGroup()` is not decoration. A 60pt blur over a full-screen image was
    /// being recomputed on every frame of the dismiss drag, which is what made the
    /// gesture stutter. Flattened into one texture, moving it is nearly free.
    private var backdrop: some View {
        ArtworkImage(id: player.currentSong?.coverArt, size: .full, cornerRadius: 0)
            // Fills whatever it is given and crops the rest, which is all a backdrop has
            // to do. No `aspectRatio`: that asks the art how big it wants to be, and the
            // answer for a non-square cover is "bigger than this".
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .blur(radius: 60, opaque: true)
            .overlay(.black.opacity(0.45))
            .drawingGroup()
            .ignoresSafeArea()
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

            case .queue:
                QueueView()

            case .lyrics:
                if let song = player.currentSong {
                    LyricsView(song: song)
                }

            case .visualizer:
                VisualizerView(isPaused: dragOffset != 0)
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

    /// The quiet line Plexamp gets right: what you are actually hearing, and where you
    /// are in the queue. Every part is omitted when unknown rather than shown as a
    /// placeholder.
    private func detailLine(_ song: Song) -> some View {
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
            Button { player.toggleShuffle() } label: {
                Image(systemName: "shuffle")
                    .foregroundStyle(player.queue.isShuffled ? Color.appTint : .white.opacity(0.7))
            }
            .accessibilityLabel(player.queue.isShuffled ? "Shuffle on" : "Shuffle off")

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

            Button { player.cycleRepeat() } label: {
                Image(systemName: player.queue.repeatMode.symbol)
                    .foregroundStyle(
                        player.queue.repeatMode == .off ? .white.opacity(0.7) : Color.appTint
                    )
            }
            .accessibilityLabel("Repeat: \(player.queue.repeatMode.rawValue)")
        }
        .foregroundStyle(.white)
        .padding(.top, Metrics.itemSpacing)
    }

    /// The system slider, flanked by the usual two icons so it reads as volume rather
    /// than a second progress bar.
    private var volumeRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.fill")
            SystemVolumeSlider()
            Image(systemName: "speaker.wave.3.fill")
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

/// Its own view on purpose. It reads `elapsed`, which ticks four times a second, and
/// under `@Observable` that invalidates whatever view read it -- so inside the player's
/// body it was re-rendering the entire screen, blurred backdrop included, 4x/second.
/// Scoped here, the tick repaints a slider and two labels.
private struct PlayerSeekBar: View {
    @Environment(AppState.self) private var appState

    @State private var scrubValue: Double?

    private var player: PlaybackController { appState.player }

    private var keepAwake: Binding<Bool> {
        Binding(
            get: { appState.screenAwake.isEnabled },
            set: { appState.screenAwake.isEnabled = $0 }
        )
    }

    /// A stream with no determinable length -- a server-side transcode is chunked, so
    /// there is no duration and no seeking either.
    private var hasKnownDuration: Bool { player.duration > 0 }

    var body: some View {
        VStack(spacing: 2) {
            Slider(
                value: Binding(
                    get: { scrubValue ?? player.elapsed },
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

            HStack {
                Text(Int(scrubValue ?? player.elapsed).asDuration)
                Spacer()
                // Rather than "0:00", which reads as a bug -- and was one.
                Text(
                    hasKnownDuration
                        ? Int(max(player.duration - (scrubValue ?? player.elapsed), 0)).asDuration
                        : "--:--"
                )
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.6))
        }
        .padding(.horizontal, 24)
        .padding(.top, 6)
        // A track change during a scrub would otherwise leave the thumb pinned at a
        // position in the *previous* song.
        .onChange(of: player.currentSong?.id) { scrubValue = nil }
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
              !queue.upNext.isEmpty,
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
