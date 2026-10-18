import SwiftUI

/// The player's visualiser mode: Plexamp's visualisers, chosen with Select Visualizer and
/// remembered, Retrospect until someone chooses.
///
/// It behaves as Plexamp's does where the artwork would be:
///
/// - **Swipe** sideways for the next or previous visualiser.
/// - **Tap** to go back to the artwork; **long-press** for Select Visualizer.
/// - **Paused**, a visualiser that is not meant to stay up while idle gives way to the
///   artwork until the music starts again.
///
/// The canvas spans the screen's width at the artwork's height, which is the shape
/// Plexamp gives it, and so the shape its shaders were drawn for.
struct VisualizerView: View {
    @Environment(AppState.self) private var appState
    @Environment(ArtworkStore.self) private var artwork

    @AppStorage(VisualizerProgram.storageKey) private var programName = VisualizerProgram.defaultName
    @AppStorage(VisualizerProgram.highQualityKey) private var highQuality = false

    /// Set while the player is being dragged away: the gesture matters more than the
    /// animation does during the half second someone is putting the player away.
    var isPaused = false
    var onTap: () -> Void = {}
    var onLongPress: () -> Void = {}

    @State private var renderer: VisualizerRenderer?
    /// Shown briefly after a swipe, then fades — the name is useful the moment it changes
    /// and clutter thereafter.
    @State private var labelShownAt: Date?

    private var player: PlaybackController { appState.player }
    private var program: VisualizerProgram { VisualizerProgram.named(programName) }
    private var isIdle: Bool { !player.isPlaying && !program.displayWhenIdle }

    /// The seekbar's loudness for this track: the same 128 LUFS points Plex hands
    /// Plexamp, which is what its Soundprint draws.
    private var loudness: [Float]? {
        guard let id = player.currentSong?.id else { return nil }
        return appState.seekbarLevels.levels(for: id)
    }

    var body: some View {
        GeometryReader { geometry in
            let side = max(0, min(geometry.size.width - 48, geometry.size.height))
            ZStack {
                if isIdle || renderer == nil {
                    ArtworkImage(id: player.currentSong?.coverArt, size: .full, cornerRadius: Metrics.radiusPlayer)
                        .frame(width: side, height: side)
                        .shadow(radius: 24, y: 12)
                        .transition(.opacity)
                } else if let renderer {
                    VisualizerCanvas(
                        renderer: renderer,
                        program: program,
                        isPaused: isPaused,
                        highQuality: highQuality
                    )
                    .frame(width: geometry.size.width, height: side)
                    .transition(.opacity)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .animation(.easeInOut(duration: 0.2), value: isIdle)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onLongPressGesture(perform: onLongPress)
        // Alongside the player's own drag rather than instead of it, so a downward pull
        // still puts the player away; only a mostly sideways swipe changes visualiser.
        .simultaneousGesture(
            DragGesture(minimumDistance: 12).onEnded { value in
                let dx = value.translation.width
                guard abs(dx) > abs(value.translation.height) else { return }
                if dx <= -50 {
                    show(program.next)
                } else if dx >= 50 {
                    show(program.previous)
                }
            }
        )
        .overlay(alignment: .top) { nameLabel }
        .onAppear {
            player.startSpectrum()
            _ = activeRenderer()
        }
        // Plexamp sends the palette when the visualiser appears and on every track
        // change after, which is what fades it from one cover's colours to the next.
        .task(id: player.currentSong?.coverArt) {
            guard let colours = await VisualizerArtworkPalette.colours(
                for: player.currentSong?.coverArt, artwork: artwork
            ) else { return }
            activeRenderer()?.feed.setPalette(colours)
        }
        // Sent when known; a track whose levels have not arrived keeps the last track's,
        // as Plexamp keeps them when a track has none.
        .onChange(of: loudness, initial: true) { _, levels in
            guard let levels else { return }
            activeRenderer()?.feed.setLoudness(VisualizerLoudness.texels(from: levels))
        }
    }

    /// Made on first use rather than in `onAppear` alone, since the palette and loudness
    /// can arrive in the same pass as the view does.
    private func activeRenderer() -> VisualizerRenderer? {
        if let renderer { return renderer }
        let feed = VisualizerFeed.shared(buffer: appState.spectrumBuffer)
        feed.player = player
        let made = VisualizerRenderer.shared(feed: feed, program: program)
        renderer = made
        return made
    }

    private func show(_ next: VisualizerProgram) {
        guard next != program else { return }
        programName = next.name
        labelShownAt = .now
    }

    @ViewBuilder
    private var nameLabel: some View {
        if let shownAt = labelShownAt {
            Text(program.name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.ultraThinMaterial, in: Capsule())
                .task(id: shownAt) {
                    try? await Task.sleep(for: .seconds(1.4))
                    withAnimation(.easeOut(duration: 0.4)) { labelShownAt = nil }
                }
                .transition(.opacity)
        }
    }
}

/// Plexamp's Select Visualizer: every visualiser, the current one ticked. Choosing one
/// switches to it there and then, behind the sheet, which stays until closed — so
/// several can be tried in a row.
struct VisualizerPicker: View {
    @AppStorage(VisualizerProgram.storageKey) private var programName = VisualizerProgram.defaultName
    @Environment(\.dismiss) private var dismiss

    /// Called on every choice: from the artwork, choosing a visualiser also shows it.
    var onSelect: () -> Void = {}

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List(VisualizerProgram.all) { program in
                    Button {
                        programName = program.name
                        onSelect()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "waveform")
                                .foregroundStyle(.secondary)
                            Text(program.name)
                                .foregroundStyle(.primary)
                            Spacer()
                            if program.name == VisualizerProgram.named(programName).name {
                                Image(systemName: "checkmark")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(Color.appTint)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .id(program.name)
                }
                .onAppear { proxy.scrollTo(VisualizerProgram.named(programName).name, anchor: .center) }
            }
            .navigationTitle("Select Visualizer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
