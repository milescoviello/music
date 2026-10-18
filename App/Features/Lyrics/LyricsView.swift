import SwiftUI

struct LyricsView: View {
    @Environment(AppState.self) private var appState
    @Environment(PlayerSettings.self) private var settings

    let song: Song

    @State private var lyrics: StructuredLyrics?
    @State private var state: LoadState = .loading
    @State private var scrollPosition = ScrollPosition(idType: Int.self)
    @State private var resumeAutoScrollAt: Date?
    @State private var activeIndex: Int?
    /// The song whose lyrics are in `lyrics`. Not `song.id`: that changes a moment before
    /// `load()` replaces the lyrics, and the read-along must not be asked about the old
    /// lyrics under the new song's name.
    @State private var loadedSongID: String?
    @State private var readAlong = LyricsReadAlong()

    private enum LoadState { case loading, loaded, missing }

    private var player: PlaybackController { appState.player }
    private var lines: [LyricLine] { lyrics?.lines ?? [] }
    private var isSynced: Bool { lyrics?.synced == true }

    var body: some View {
        Group {
            switch state {
            case .loading:
                ProgressView()
            case .missing:
                missingState
            case .loaded:
                lyricsScroller
            }
        }
        .task(id: song.id) { await load() }
        .task(id: ReadAlongRequest(songID: loadedSongID, romanizes: settings.romanizesLyrics)) {
            await readAlong.update(romanize: settings.romanizesLyrics)
        }
        // The clock is a view of its own, because it reads `elapsed`, which ticks four
        // times a second: read here, it re-ran this body, every line of the lyrics
        // included, on every tick. Out there it re-runs an empty view, and this one runs
        // only when the line changes.
        .background {
            LyricClock(lines: lines, isSynced: isSynced, offset: lyrics?.offset ?? 0) { index in
                lineChanged(to: index)
            }
        }
    }

    /// Only assigns when the line actually changes: the clock ticks four times a second
    /// but a track has ~40 lines, so this keeps re-renders in the tens, not thousands.
    private func lineChanged(to index: Int?) {
        guard index != activeIndex else { return }
        activeIndex = index
        guard shouldAutoScroll, let index else { return }
        withAnimation(.easeInOut(duration: 0.4)) {
            scrollPosition.scrollTo(id: index, anchor: UnitPoint(x: 0.5, y: 0.32))
        }
    }

    private var lyricsScroller: some View {
        ScrollView {
            // A plain VStack, not lazy: Text is cheap, tracks run 30-150 lines, and
            // programmatic scrolling to an unrealised lazy row silently no-ops.
            VStack(spacing: 0) {
                Spacer().frame(height: 140)

                // Identity must be the index -- lyrics repeat, so `id: \.self` on the
                // string would break both scrolling and highlighting.
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(line.value)
                            .font(index == activeIndex
                                ? .title2.weight(.bold)
                                : .title3.weight(.semibold))
                        // Beneath the line rather than in its place: the original is
                        // what is being sung, and the highlight stays on it.
                        if settings.romanizesLyrics, let romanized = readAlong.romanized[index] {
                            Text(romanized)
                                .font(index == activeIndex
                                    ? .body.weight(.semibold)
                                    : .callout.weight(.medium))
                                .opacity(0.75)
                        }
                    }
                    .foregroundStyle(lineColor(for: index))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 20)
                    .id(index)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard isSynced, let start = line.start else { return }
                        player.seek(to: Double(start + (lyrics?.offset ?? 0)) / 1000)
                    }
                }

                Spacer().frame(height: 200)
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: activeIndex)
        }
        .scrollPosition($scrollPosition, anchor: UnitPoint(x: 0.5, y: 0.32))
        // Touch it and auto-scroll stops dead; it resumes 4s after the scroll settles
        // so the view never fights the user's finger.
        .onScrollPhaseChange { _, phase in
            if phase == .interacting || phase == .decelerating {
                resumeAutoScrollAt = .distantFuture
            } else if phase == .idle, resumeAutoScrollAt == .distantFuture {
                resumeAutoScrollAt = .now.addingTimeInterval(4)
            }
        }
        .overlay(alignment: .top) {
            if !isSynced {
                Text("Lyrics not timed")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.top, 8)
            }
        }
        .overlay(alignment: .topTrailing) { readAlongMenu }
    }

    /// Here rather than in Settings: it is wanted song by song, while reading along.
    private var readAlongMenu: some View {
        @Bindable var settings = settings

        return Menu {
            Section {
                Toggle(isOn: $settings.romanizesLyrics) {
                    Label("Romanize", systemImage: "textformat.abc")
                }
            } header: {
                if let language = readAlong.language,
                   let name = Locale.current.localizedString(forLanguageCode: language) {
                    Text("\(name) Lyrics")
                }
            }
        } label: {
            Image(systemName: "translate")
                .font(.body.weight(.semibold))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 36, height: 36)
                .background(.white.opacity(0.12), in: Circle())
        }
        .accessibilityLabel("Lyrics Options")
        .padding(.top, 4)
        .padding(.trailing, 16)
    }

    private var missingState: some View {
        VStack(spacing: 8) {
            Image(systemName: "quote.bubble")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("No lyrics for this track")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    private func lineColor(for index: Int) -> Color {
        guard let activeIndex else { return .white.opacity(0.5) }
        if index == activeIndex { return .white }
        return .white.opacity(abs(index - activeIndex) >= 3 ? 0.3 : 0.5)
    }

    private var shouldAutoScroll: Bool {
        guard isSynced else { return false }
        if scrollPosition.isPositionedByUser { return false }
        guard let resumeAutoScrollAt else { return true }
        return resumeAutoScrollAt < .now
    }

    private func load() async {
        state = .loading
        loadedSongID = nil
        activeIndex = nil
        resumeAutoScrollAt = nil

        // Disk first: for a downloaded track it is already there, and it removes a
        // request plus a visible delay on every track change.
        var sets = await LyricsStore.shared.load(songID: song.id) ?? []

        if sets.isEmpty {
            sets = (try? await appState.client.lyrics(songID: song.id)) ?? []
        }
        guard !Task.isCancelled else { return }

        // Prefer a synced set, then one matching the device language.
        let preferredLanguage = Locale.preferredLanguages.first?.prefix(2).lowercased()
        let synced = sets.filter(\.synced)
        lyrics = synced.first { $0.lang?.lowercased().hasPrefix(preferredLanguage ?? "") == true }
            ?? synced.first
            ?? sets.first

        state = (lyrics?.lines.isEmpty ?? true) ? .missing : .loaded
        if let lyrics, state == .loaded {
            readAlong.show(lyrics, songID: song.id)
            loadedSongID = song.id
        }
    }
}

/// What the read-along is asked to bring up to date: the lyrics on screen, and the
/// reader's choices for them.
private struct ReadAlongRequest: Equatable {
    var songID: String?
    var romanizes: Bool
}

/// Which line is being sung, told to the lyrics whenever it changes.
private struct LyricClock: View {
    @Environment(AppState.self) private var appState

    let lines: [LyricLine]
    let isSynced: Bool
    let offset: Int
    let onChange: (Int?) -> Void

    var body: some View {
        Color.clear
            .onChange(of: currentLineIndex) { _, index in onChange(index) }
    }

    /// Binary search rather than a scan: called on every tick.
    private var currentLineIndex: Int? {
        guard isSynced, !lines.isEmpty else { return nil }

        let now = Int(appState.player.elapsed * 1000) - offset
        var low = 0
        var high = lines.count - 1
        var result: Int?

        while low <= high {
            let mid = (low + high) / 2
            guard let start = lines[mid].start else {
                low = mid + 1
                continue
            }
            if start <= now {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return result
    }
}
