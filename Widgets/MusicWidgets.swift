import AppIntents
import SwiftUI
import WidgetKit

/// The home screen's and the lock screen's Music: the song playing, with its controls, and
/// today's Made for You, a tap from playing. Both read what the app wrote (`WidgetSnapshot`)
/// and ask it to reload them when that changes; they never fetch anything themselves.
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
        // The app asks for a reload whenever what it shows changes.
        completion(Timeline(entries: [current()], policy: .never))
    }

    private func current() -> SnapshotEntry {
        let snapshot = WidgetSnapshot.load()
        var covers: [Int: Data] = [:]
        for mix in snapshot?.mixes ?? [] {
            covers[mix.number] = WidgetSnapshot.image(WidgetSnapshot.mixCoverName(mix.number))
        }
        return SnapshotEntry(date: .now, snapshot: snapshot, cover: WidgetSnapshot.image(WidgetSnapshot.coverName),
                             mixCovers: covers)
    }
}

private let accent = Color(red: 0.98, green: 0.28, blue: 0.36)

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
        .description("The song playing, with play, pause and skip.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

struct NowPlayingView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry

    private var snapshot: WidgetSnapshot? { entry.snapshot }

    var body: some View {
        Group {
            switch family {
            case .accessoryRectangular: lockScreen
            case .systemMedium: medium
            default: small
            }
        }
        .containerBackground(for: .widget) {
            if family == .accessoryRectangular {
                Color.clear
            } else {
                Color.black
            }
        }
    }

    private var titleText: String { snapshot?.title ?? (AppGroup.container == nil ? "Open Music" : "Nothing playing") }

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            Cover(data: entry.cover).frame(width: 64, height: 64)
            Spacer(minLength: 0)
            Text(titleText).font(.subheadline.weight(.semibold)).lineLimit(1)
            Text(snapshot?.artist ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            HStack {
                Spacer()
                playButton.font(.title3)
            }
        }
        .foregroundStyle(.white)
    }

    private var medium: some View {
        HStack(spacing: 14) {
            Cover(data: entry.cover, corner: 14).frame(width: 118, height: 118)
            VStack(alignment: .leading, spacing: 4) {
                Text(titleText).font(.headline).lineLimit(2)
                Text(snapshot?.artist ?? "").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                Text(snapshot?.album ?? "").font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                Spacer(minLength: 0)
                HStack(spacing: 22) {
                    Button(intent: PreviousTrackIntent()) { Image(systemName: "backward.fill") }
                    playButton
                    Button(intent: NextTrackIntent()) { Image(systemName: "forward.fill") }
                }
                .font(.title3)
                .buttonStyle(.plain)
            }
        }
        .foregroundStyle(.white)
    }

    private var lockScreen: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(titleText).font(.headline).lineLimit(1)
                Text(snapshot?.artist ?? "").font(.caption).lineLimit(1)
            }
            Spacer(minLength: 4)
            playButton.font(.title3)
        }
    }

    private var playButton: some View {
        Button(intent: TogglePlaybackIntent()) {
            Image(systemName: snapshot?.isPlaying == true ? "pause.fill" : "play.fill")
        }
        .buttonStyle(.plain)
        .foregroundStyle(family == .accessoryRectangular ? Color.primary : accent)
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
            Text("Made for You").font(.headline).foregroundStyle(.white)
            if mixes.isEmpty {
                Spacer()
                Text("Open Music to make today's mixes.").font(.caption).foregroundStyle(.secondary)
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
        .containerBackground(for: .widget) { Color.black }
    }
}
