import SwiftUI

/// A video full screen, upright or on its side: a YouTube result being watched from search,
/// or the song's own video from the player.
///
/// Watching, the controls are the video's own, with Add to Library, and closing puts the
/// music back where it was. For the song's video they are the player's -- the same play,
/// pause, seek, previous and next the lock screen has -- and closing leaves it playing in
/// the player.
struct VideoFullScreenView: View {
    @Environment(AppState.self) private var appState
    @Environment(VideoService.self) private var videos
    @Environment(\.dismiss) private var dismiss

    /// The search result being watched; nil for the song's own video.
    let watching: VideoClient.Video?

    @State private var showsControls = true
    @State private var scrub: Double?
    @State private var adding: VideoClient.Video?
    @State private var hideTask: Task<Void, Never>?

    private var player: PlaybackController { appState.player }
    private var progress: VideoService.Progress { videos.progress }
    private var isPlaying: Bool { watching == nil ? player.isPlaying : progress.isPlaying }
    private var elapsed: Double { scrub ?? progress.elapsed }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VideoSurface(engine: videos.engine)
                .ignoresSafeArea()
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture { toggleControls() }

            if progress.isWaiting, videos.watchError == nil {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                    .allowsHitTesting(false)
            }

            if let error = videos.watchError, watching != nil {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                    Text("This video won't play")
                        .font(.headline)
                    Text(error)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.7))
                }
                .foregroundStyle(.white)
                .padding(32)
            }

            if showsControls {
                controls
                    .transition(.opacity)
            }
        }
        .statusBarHidden(!showsControls)
        .persistentSystemOverlays(showsControls ? .automatic : .hidden)
        .animation(.easeInOut(duration: 0.2), value: showsControls)
        .addToLibrary($adding)
        .onAppear {
            VideoOrientation.allowLandscape(true)
            scheduleHide()
        }
        .onDisappear {
            hideTask?.cancel()
            VideoOrientation.allowLandscape(false)
        }
        .onChange(of: isPlaying) { _, playing in
            if playing { scheduleHide() } else { showControls() }
        }
        // The song's video gave way to its track (no video for the next song, or it
        // failed): nothing left to show full screen.
        .onChange(of: videos.isStandingIn) { _, standing in
            if watching == nil, !standing { dismiss() }
        }
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Button {
                    close()
                } label: {
                    Image(systemName: watching == nil ? "chevron.down" : "xmark")
                        .font(.body.weight(.semibold))
                        .frame(width: Metrics.minimumTouchTarget, height: Metrics.minimumTouchTarget)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(watching == nil ? "Close full screen" : "Close video")

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(2)
                    if let subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)

                if let watching {
                    Button {
                        adding = watching
                    } label: {
                        Label("Add to Library", systemImage: "plus.circle")
                            .labelStyle(.iconOnly)
                            .font(.title3)
                            .frame(width: Metrics.minimumTouchTarget, height: Metrics.minimumTouchTarget)
                    }
                    .accessibilityLabel("Add to Library")
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 24)
            .background(alignment: .top) {
                LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
            }

            Spacer()

            VStack(spacing: 6) {
                scrubber
                transport
            }
            .padding(.horizontal, 20)
            .padding(.top, 28)
            .padding(.bottom, 12)
            .background(alignment: .bottom) {
                LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
            }
        }
        .foregroundStyle(.white)
    }

    private var scrubber: some View {
        let length = max(progress.duration, 1)
        return VStack(spacing: 2) {
            Slider(
                value: Binding(get: { min(elapsed, length) }, set: { scrub = $0 }),
                in: 0...length,
                onEditingChanged: { editing in
                    if !editing, let scrub {
                        seek(to: scrub)
                        self.scrub = nil
                    }
                    if editing { hideTask?.cancel() } else { scheduleHide() }
                }
            )
            .tint(.white)
            .disabled(progress.duration <= 0)

            HStack {
                Text(Int(elapsed).asDuration)
                Spacer()
                Text(Int(progress.duration).asDuration)
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.white.opacity(0.7))
        }
    }

    private var transport: some View {
        HStack(spacing: 40) {
            if watching == nil {
                Button { player.previous() } label: {
                    Image(systemName: "backward.fill").font(.title2)
                }
                .accessibilityLabel("Previous track")
            } else {
                Button { videos.skip(by: -10) } label: {
                    Image(systemName: "gobackward.10").font(.title2)
                }
                .accessibilityLabel("Back 10 seconds")
            }

            Button {
                if watching == nil { player.togglePlayPause() } else { videos.togglePlayPause() }
                scheduleHide()
            } label: {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 56))
            }
            .accessibilityLabel(isPlaying ? "Pause" : "Play")

            if watching == nil {
                Button { player.next() } label: {
                    Image(systemName: "forward.fill").font(.title2)
                }
                .accessibilityLabel("Next track")
            } else {
                Button { videos.skip(by: 10) } label: {
                    Image(systemName: "goforward.10").font(.title2)
                }
                .accessibilityLabel("Forward 10 seconds")
            }
        }
    }

    private var title: String {
        watching?.title ?? player.currentSong?.title ?? videos.current?.title ?? ""
    }

    private var subtitle: String? {
        if let watching { return watching.channel.isEmpty ? nil : watching.channel }
        return player.currentSong?.artist
    }

    private func seek(to seconds: Double) {
        if watching == nil { player.seek(to: seconds) } else { videos.seek(to: seconds) }
    }

    private func close() {
        if watching != nil { videos.stopWatching() }
        dismiss()
    }

    private func toggleControls() {
        if showsControls {
            hideTask?.cancel()
            showsControls = false
        } else {
            showControls()
        }
    }

    private func showControls() {
        showsControls = true
        scheduleHide()
    }

    /// Out of the way three seconds after the last touch, while it plays.
    private func scheduleHide() {
        hideTask?.cancel()
        guard isPlaying else { return }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, isPlaying, scrub == nil else { return }
            showsControls = false
        }
    }
}
