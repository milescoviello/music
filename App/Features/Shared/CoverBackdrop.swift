import Observation
import SwiftUI

/// The cover's colours behind every page, as the Linux app has them behind its whole
/// window: three of the cover's own colours (`CoverColours`), each a wide pool of light
/// drifting slowly over a dark ground. A page with a cover of its own (an album, an artist)
/// shows its own; every other page, the playing song's.
///
/// The pools move a step a second, each too small to see, so the blend never quite
/// repeats; nothing else on the page moves. Only while music plays, as on the desktop,
/// and not in Low Power Mode: still, the page is not redrawn every second for nothing.
struct CoverBackdrop: View {
    let cover: String?

    @Environment(ArtworkStore.self) private var artwork
    @Environment(AppState.self) private var appState
    @State private var pools = CoverColours.resting
    /// Where in the drift this page starts, so two pages are not in step.
    @State private var start = Date().addingTimeInterval(-Double.random(in: 0..<1_000))

    var body: some View {
        let drifts = appState.player.isPlaying && !ProcessInfo.processInfo.isLowPowerModeEnabled
        TimelineView(Drift(moves: drifts)) { context in
            let time = context.date.timeIntervalSince(start)
            GeometryReader { geometry in
                ZStack {
                    Self.colour(CoverColours.ground)
                    ForEach(0..<min(pools.count, 3), id: \.self) { index in
                        pool(index, time: time, in: geometry.size)
                    }
                }
                .drawingGroup()
            }
        }
        // Started afresh when it stops or starts moving, from where it is then.
        .id(drifts)
        .animation(.easeInOut(duration: 1.2), value: pools)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: cover) {
            guard let cover else {
                pools = CoverColours.resting
                return
            }
            guard let colours = await VisualizerArtworkPalette.colours(for: cover, artwork: artwork) else { return }
            pools = CoverColours.pick(colours)
        }
    }

    /// One pool: strongest at its centre, falling smoothly to nothing at its edge, so no
    /// rim shows where it ends (the stops follow the Linux backdrop's smoothstep).
    private func pool(_ index: Int, time: Double, in size: CGSize) -> some View {
        let centre = CoverColours.centre(index, time: time)
        let radius = CoverColours.radius(width: size.width, height: size.height)
        let colour = Self.colour(pools[index])
        let strength = CoverColours.poolStrength
        return RadialGradient(
            gradient: Gradient(stops: [
                .init(color: colour.opacity(strength), location: 0),
                .init(color: colour.opacity(strength * 0.844), location: 0.25),
                .init(color: colour.opacity(strength * 0.5), location: 0.5),
                .init(color: colour.opacity(strength * 0.156), location: 0.75),
                .init(color: colour.opacity(0), location: 1),
            ]),
            center: .center,
            startRadius: 0,
            endRadius: radius
        )
        .frame(width: radius * 2, height: radius * 2)
        .position(x: centre.x * size.width, y: centre.y * size.height)
    }

    static func colour(_ rgb: VisualizerPalette.RGB) -> Color {
        Color(red: rgb.r / 255, green: rgb.g / 255, blue: rgb.b / 255)
    }

    /// A step a second while it moves; standing still, the moment it stopped and no other.
    private struct Drift: TimelineSchedule {
        let moves: Bool

        func entries(from startDate: Date, mode: TimelineScheduleMode) -> UnfoldFirstSequence<Date> {
            let moves = moves && mode == .normal
            return sequence(first: startDate) { moves ? $0.addingTimeInterval(1) : nil }
        }
    }
}

/// The accent the playing song lends the whole app, as on Linux: the most saturated of its
/// cover's colours. `Color.appTint` reads it, so every use of the accent follows the song.
@Observable
final class CoverTint: @unchecked Sendable {
    static let shared = CoverTint()

    /// Nil before any song's colours are in: the app's own pink.
    private(set) var accent: Color?

    private init() {}

    /// Follows the song now playing; called whenever its cover changes.
    @MainActor
    func follow(_ cover: String?, artwork: ArtworkStore) async {
        guard let cover else { return }
        guard let colours = await VisualizerArtworkPalette.colours(for: cover, artwork: artwork) else { return }
        let pools = CoverColours.pick(colours)
        guard let rgb = CoverColours.accent(from: pools, lightness: 0.62) else { return }
        accent = Color(red: rgb.r, green: rgb.g, blue: rgb.b)
        // The widgets draw the same colours behind themselves.
        WidgetPublisher.shared.colours(pools: pools, accent: rgb)
    }
}

/// Which cover a page's backdrop shows, when the page has one of its own.
private struct BackdropCoverKey: PreferenceKey {
    static let defaultValue: String? = nil

    static func reduce(value: inout String?, nextValue: () -> String?) {
        value = value ?? nextValue()
    }
}

private struct PageBackdrop: ViewModifier {
    @Environment(AppState.self) private var appState

    func body(content: Content) -> some View {
        content
            // Lists and forms drop their own black, so the colours show between the rows.
            .scrollContentBackground(.hidden)
            .backgroundPreferenceValue(BackdropCoverKey.self) { cover in
                CoverBackdrop(cover: cover ?? appState.player.currentSong?.coverArt)
                    .ignoresSafeArea()
            }
    }
}

extension View {
    /// The cover's colours behind a page. Attach to each tab's root and to every pushed
    /// page (`musicDestinations` does that for the pushed ones).
    func pageBackdrop() -> some View {
        modifier(PageBackdrop())
    }

    /// A page's own cover behind it, rather than the playing song's: an album's, an
    /// artist's.
    func backdropCover(_ cover: String?) -> some View {
        preference(key: BackdropCoverKey.self, value: cover)
    }

    /// A row of a list that lies straight on the cover's colours: no black of its own.
    func clearRow() -> some View {
        listRowBackground(Color.clear)
    }

    /// A row of a grouped list, as the Linux app's lists are: light glass over the colours.
    func glassRow() -> some View {
        listRowBackground(Color.white.opacity(0.07))
    }
}
