import AppIntents
import SwiftUI
import WidgetKit

/// The home screen's and the lock screen's Music: the song playing, with its controls, and
/// today's Made for You, a tap from playing. Both read what the app wrote (`WidgetSnapshot`)
/// and ask it to reload them when that changes; they never fetch anything themselves.
///
/// They wear the app's look, which is the Linux app's: the playing song's cover colours as
/// pools of light behind them, light glass, the song's accent, and the Linux player's lines
/// (the artist, the title in bold, the album; the codec line with the stars and the heart).
@main
struct MusicWidgets: WidgetBundle {
    var body: some Widget {
        NowPlayingWidget()
        MadeForYouWidget()
    }
}

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
    let cover: Data?
    let mixCovers: [Int: Data]
    var pinnedCovers: [Int: Data] = [:]
}

struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: .now, snapshot: WidgetSnapshot(title: "Song", artist: "Artist", mixes: [
            .init(number: 1, title: "Heavy Rotation", subtitle: ""), .init(number: 2, title: "Mix", subtitle: ""),
        ]), cover: nil, mixCovers: [:])
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(current())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        // The app asks for a reload whenever what it shows changes; the progress bar runs
        // on its own between.
        completion(Timeline(entries: [current()], policy: .never))
    }

    private func current() -> SnapshotEntry {
        let snapshot = WidgetSnapshot.load()
        var covers: [Int: Data] = [:]
        for mix in snapshot?.mixes ?? [] {
            covers[mix.number] = WidgetSnapshot.image(WidgetSnapshot.mixCoverName(mix.number))
        }
        var pinned: [Int: Data] = [:]
        for number in (snapshot?.pinned ?? []).indices.map({ $0 + 1 }) {
            pinned[number] = WidgetSnapshot.image(WidgetSnapshot.pinnedCoverName(number))
        }
        return SnapshotEntry(date: .now, snapshot: snapshot, cover: WidgetSnapshot.image(WidgetSnapshot.coverName),
                             mixCovers: covers, pinnedCovers: pinned)
    }
}

/// The app's own pink: the accent before a song's colours are known.
private let pink = Color(red: 0.98, green: 0.28, blue: 0.36)

extension WidgetSnapshot {
    /// The playing song's accent, as the app's.
    var accentColor: Color {
        guard let accent, accent.count == 3 else { return pink }
        return Color(red: accent[0], green: accent[1], blue: accent[2])
    }
}

// MARK: - The app's look

/// The app's backdrop, still: three of the cover's colours, each a wide pool of light over
/// a dark ground, where the app's pools start their slow drift (`CoverColours`).
struct CoverGround: View {
    let pools: [[Double]]?

    /// Before there is a cover: the app's accent, a deep blue and a violet.
    private static let resting: [[Double]] = [[150, 40, 60], [30, 50, 110], [70, 40, 110]]
    private static let centres: [(x: Double, y: Double)] = [(0.25, 0.5), (0.92, 0.13), (0.26, 0.91)]

    var body: some View {
        let colours = (pools?.count == 3 ? pools : nil) ?? Self.resting
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let radius = 0.85 * (width * width + height * height).squareRoot() / 1.6
            ZStack {
                Color(red: 10 / 255, green: 10 / 255, blue: 14 / 255)
                ForEach(0..<3, id: \.self) { index in
                    let rgb = colours[index].count == 3 ? colours[index] : Self.resting[index]
                    let colour = Color(red: rgb[0] / 255, green: rgb[1] / 255, blue: rgb[2] / 255)
                    RadialGradient(
                        gradient: Gradient(stops: [
                            .init(color: colour.opacity(0.62), location: 0),
                            .init(color: colour.opacity(0.52), location: 0.25),
                            .init(color: colour.opacity(0.31), location: 0.5),
                            .init(color: colour.opacity(0.1), location: 0.75),
                            .init(color: colour.opacity(0), location: 1),
                        ]),
                        center: .center, startRadius: 0, endRadius: radius
                    )
                    .frame(width: radius * 2, height: radius * 2)
                    .position(x: Self.centres[index].x * width, y: Self.centres[index].y * height)
                }
            }
        }
    }
}

extension View {
    /// The Linux app's glass: a light fill and a hairline edge.
    func glass(_ corner: CGFloat = 10) -> some View {
        background(.white.opacity(0.075), in: RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(.white.opacity(0.07), lineWidth: 1)
            }
    }
}

private struct Cover: View {
    let data: Data?
    var corner: CGFloat = 10

    var body: some View {
        Group {
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Color.white.opacity(0.1)
                    Image(systemName: "music.note").font(.title2).foregroundStyle(.secondary)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

// MARK: - Now Playing

struct NowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NowPlaying", provider: SnapshotProvider()) { entry in
            NowPlayingView(entry: entry)
        }
        .configurationDisplayName("Now Playing")
        .description("The song playing, with its progress and controls; your pinned playlists when nothing is.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}

struct NowPlayingView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry

    private var snapshot: WidgetSnapshot? { entry.snapshot }
    private var accent: Color { snapshot?.accentColor ?? pink }
    private var pinned: [WidgetSnapshot.Pinned] { snapshot?.pinned ?? [] }
    private var hasSong: Bool { snapshot?.title != nil }
    private var isPlaying: Bool { snapshot?.isPlaying == true }
    private var isAccessory: Bool {
        family == .accessoryRectangular || family == .accessoryCircular || family == .accessoryInline
    }

    var body: some View {
        Group {
            switch family {
            case .accessoryRectangular: lockScreen
            case .accessoryCircular: circular
            case .accessoryInline: inline
            // Nothing playing: the pinned playlists, a tap from playing, rather than a
            // blank cover. The medium one keeps a line to resume what was paused.
            case .systemLarge:
                if hasSong { large } else { largeIdle }
            case .systemMedium:
                if !isPlaying && !pinned.isEmpty { pinnedMedium } else { medium }
            default:
                if !hasSong && !pinned.isEmpty { pinnedSmall } else { small }
            }
        }
        .tint(accent)
        .containerBackground(for: .widget) {
            if isAccessory {
                Color.clear
            } else {
                CoverGround(pools: snapshot?.pools)
            }
        }
    }

    private var titleText: String { snapshot?.title ?? (AppGroup.container == nil ? "Open Music" : "Nothing playing") }

    private var albumLine: String { snapshot?.album ?? "" }

    // MARK: Pieces

    /// The Linux player bar's play button: white, with a black glyph.
    private func playButton(_ size: CGFloat) -> some View {
        Button(intent: TogglePlaybackIntent()) {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: size * 0.4, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: size, height: size)
                .background(.white, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isPlaying ? "Pause" : "Play")
    }

    private func controls(_ size: CGFloat) -> some View {
        HStack(spacing: size * 0.6) {
            Button(intent: PreviousTrackIntent()) { Image(systemName: "backward.fill") }
                .accessibilityLabel("Previous")
            playButton(size)
            Button(intent: NextTrackIntent()) { Image(systemName: "forward.fill") }
                .accessibilityLabel("Next")
        }
        .font(.system(size: size * 0.45))
        .foregroundStyle(.white)
        .buttonStyle(.plain)
    }

    /// The song's progress, running by itself while it plays.
    @ViewBuilder
    private var bar: some View {
        if let span = snapshot?.playingSpan {
            ProgressView(timerInterval: span, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                .progressViewStyle(.linear)
        } else {
            ProgressView(value: snapshot?.fraction ?? 0)
                .progressViewStyle(.linear)
        }
    }

    /// The bar between the time gone and the song's length.
    private var progressRow: some View {
        HStack(spacing: 6) {
            Group {
                if let span = snapshot?.playingSpan {
                    Text(timerInterval: span, countsDown: false)
                } else {
                    Text(Self.time(snapshot?.elapsed ?? 0))
                }
            }
            .frame(width: 34, alignment: .leading)
            bar
            Text(Self.time(snapshot?.duration ?? 0))
                .frame(width: 34, alignment: .trailing)
        }
        .font(.system(size: 10, weight: .semibold).monospacedDigit())
        .foregroundStyle(.white.opacity(0.6))
    }

    private static func time(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// The Linux player's three lines: the artist, the title in bold, the album dimmer.
    private func titleBlock(_ scale: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            if let artist = snapshot?.artist {
                Text(artist).font(.system(size: 12 * scale, weight: .bold)).lineLimit(1)
            }
            Text(titleText).font(.system(size: 14 * scale, weight: .heavy)).lineLimit(1)
            if !albumLine.isEmpty {
                Text(albumLine)
                    .font(.system(size: 11 * scale, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
        }
    }

    /// The Linux player's codec line: the format, the stars, the heart.
    private var codecLine: some View {
        HStack(spacing: 4) {
            if let quality = snapshot?.quality {
                Text(quality)
            }
            if hasSong {
                let rating = snapshot?.rating ?? 0
                HStack(spacing: 0) {
                    ForEach(1...5, id: \.self) { value in
                        Image(systemName: value <= rating ? "star.fill" : "star")
                            .foregroundStyle(value <= rating ? accent : .white.opacity(0.4))
                    }
                }
                .font(.system(size: 8))
            }
            if snapshot?.isFavourite == true {
                Image(systemName: "heart.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(accent)
            }
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.white.opacity(0.6))
        .lineLimit(1)
    }

    private func pinnedButton(_ playlist: WidgetSnapshot.Pinned, number: Int, named: Bool) -> some View {
        Button(intent: PlayWidgetPlaylistIntent(id: playlist.id)) {
            VStack(alignment: .leading, spacing: 3) {
                Cover(data: entry.pinnedCovers[number], corner: 8).aspectRatio(1, contentMode: .fit)
                if named {
                    Text(playlist.name).font(.caption2.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                }
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }

    /// Up to four pinned playlists in a row, named or not; short rows keep their covers
    /// the size of a full one.
    private func pinnedRow(named: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(Array(pinned.prefix(4).enumerated()), id: \.offset) { item in
                pinnedButton(item.element, number: item.offset + 1, named: named)
            }
            ForEach(0..<(4 - min(4, pinned.count)), id: \.self) { _ in
                Color.clear.frame(maxWidth: .infinity)
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .bold))
            .tracking(0.5)
            .foregroundStyle(.white.opacity(0.55))
    }

    // MARK: Sizes

    private var small: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top) {
                Cover(data: entry.cover).frame(width: 58, height: 58)
                Spacer(minLength: 0)
                playButton(32)
            }
            Spacer(minLength: 0)
            Text(titleText).font(.subheadline.weight(.heavy)).lineLimit(1)
            Text(snapshot?.artist ?? "").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            if hasSong {
                bar.padding(.top, 3)
            }
        }
        .foregroundStyle(.white)
    }

    private var medium: some View {
        HStack(spacing: 14) {
            Cover(data: entry.cover, corner: 12).frame(width: 116, height: 116)
            VStack(alignment: .leading, spacing: 3) {
                titleBlock(1)
                codecLine
                Spacer(minLength: 2)
                if hasSong { progressRow }
                controls(30).frame(maxWidth: .infinity)
            }
        }
        .foregroundStyle(.white)
    }

    private var large: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Cover(data: entry.cover, corner: 12).frame(width: 96, height: 96)
                VStack(alignment: .leading, spacing: 4) {
                    titleBlock(1.15)
                    codecLine
                }
                Spacer(minLength: 0)
            }
            progressRow
            controls(38).frame(maxWidth: .infinity)
            if let upNext = snapshot?.upNext, !upNext.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    sectionTitle("Up Next")
                    ForEach(Array(upNext.prefix(pinned.isEmpty ? 4 : 3).enumerated()), id: \.offset) { item in
                        HStack(spacing: 6) {
                            Text(item.element.title).font(.caption.weight(.semibold)).lineLimit(1)
                            if let artist = item.element.artist {
                                Text(artist).font(.caption).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .glass(7)
                    }
                }
            }
            Spacer(minLength: 0)
            if !pinned.isEmpty {
                pinnedRow(named: false)
            }
        }
        .foregroundStyle(.white)
    }

    /// No song at all: the pinned playlists and today's mixes, each a tap from playing.
    private var largeIdle: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Pinned")
            pinnedRow(named: true)
            let mixes = Array((snapshot?.mixes ?? []).prefix(4))
            if !mixes.isEmpty {
                sectionTitle("Made for You").padding(.top, 6)
                HStack(alignment: .top, spacing: 10) {
                    ForEach(mixes, id: \.number) { mix in
                        Button(intent: PlayWidgetMixIntent(number: mix.number)) {
                            VStack(alignment: .leading, spacing: 3) {
                                Cover(data: entry.mixCovers[mix.number], corner: 8).aspectRatio(1, contentMode: .fit)
                                Text(mix.title).font(.caption2.weight(.semibold)).lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity)
                    }
                    ForEach(0..<(4 - mixes.count), id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
    }

    /// Four covers, two by two.
    private var pinnedSmall: some View {
        let shown = Array(pinned.prefix(4).enumerated())
        return VStack(spacing: 8) {
            ForEach([0, 2], id: \.self) { start in
                HStack(spacing: 8) {
                    ForEach(shown.filter { $0.offset >= start && $0.offset < start + 2 }, id: \.offset) { item in
                        pinnedButton(item.element, number: item.offset + 1, named: false)
                    }
                    if shown.count < start + 2 { Color.clear.frame(maxWidth: .infinity) }
                }
            }
        }
    }

    /// What was paused, to resume, over the pinned playlists in a row.
    private var pinnedMedium: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if let title = snapshot?.title {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(title).font(.caption.weight(.heavy)).lineLimit(1)
                        if let artist = snapshot?.artist {
                            Text(artist).font(.caption2.weight(.semibold)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                    playButton(26)
                } else {
                    sectionTitle("Pinned")
                    Spacer(minLength: 0)
                }
            }
            pinnedRow(named: true)
        }
        .foregroundStyle(.white)
    }

    // MARK: Lock screen

    private var lockScreen: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(titleText).font(.headline).lineLimit(1)
                Text(snapshot?.artist ?? "").font(.caption).lineLimit(1)
                if hasSong { bar.padding(.top, 2) }
            }
            Spacer(minLength: 4)
            Button(intent: TogglePlaybackIntent()) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
            }
            .buttonStyle(.plain)
            .font(.title3)
        }
    }

    /// The song's progress round a play/pause button.
    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            Group {
                if let span = snapshot?.playingSpan {
                    ProgressView(timerInterval: span, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                } else {
                    ProgressView(value: snapshot?.fraction ?? 0)
                }
            }
            .progressViewStyle(.circular)
            Button(intent: TogglePlaybackIntent()) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18, weight: .bold))
            }
            .buttonStyle(.plain)
        }
    }

    private var inline: some View {
        Label {
            Text(hasSong ? [snapshot?.title, snapshot?.artist].compactMap { $0 }.joined(separator: " · ") : titleText)
        } icon: {
            Image(systemName: isPlaying ? "music.note" : "pause.fill")
        }
    }
}

// MARK: - Made for You

struct MadeForYouWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "MadeForYou", provider: SnapshotProvider()) { entry in
            MadeForYouView(entry: entry)
        }
        .configurationDisplayName("Made for You")
        .description("Today's mixes. Tap one to play it.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct MadeForYouView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry

    var body: some View {
        let mixes = Array((entry.snapshot?.mixes ?? []).prefix(family == .systemLarge ? 6 : 4))
        VStack(alignment: .leading, spacing: 8) {
            Text("Made for You").font(.headline.weight(.bold)).foregroundStyle(.white)
            if mixes.isEmpty {
                Spacer()
                Text("Open Music to make today's mixes.").font(.caption).foregroundStyle(.white.opacity(0.6))
                Spacer()
            } else {
                let columns = family == .systemLarge ? 3 : 4
                VStack(spacing: 10) {
                    ForEach(Array(stride(from: 0, to: mixes.count, by: columns)), id: \.self) { start in
                        HStack(alignment: .top, spacing: 10) {
                            ForEach(mixes[start..<min(start + columns, mixes.count)], id: \.number) { mix in
                                Button(intent: PlayWidgetMixIntent(number: mix.number)) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Cover(data: entry.mixCovers[mix.number]).aspectRatio(1, contentMode: .fit)
                                        Text(mix.title).font(.caption2.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                                    }
                                }
                                .buttonStyle(.plain)
                                .frame(maxWidth: .infinity)
                            }
                            // Short rows keep their cards the size of the full ones.
                            ForEach(0..<(columns - min(columns, mixes.count - start)), id: \.self) { _ in
                                Color.clear.frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
            }
        }
        .tint(entry.snapshot?.accentColor ?? pink)
        .containerBackground(for: .widget) { CoverGround(pools: entry.snapshot?.pools) }
    }
}
