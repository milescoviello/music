import SwiftUI
import Translation

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
    @State private var translation = LyricTranslation()
    /// The lyrics being timed by hand (`LyricsTiming`), and the song they are of: kept
    /// while it plays on into the next, so a song timed to its last line can still be saved.
    @State private var timing: LyricsTiming?
    @State private var timingSongID: String?
    @State private var isSavingTiming = false
    @State private var timingError: String?
    /// A line's words being changed: which line, and the words so far.
    @State private var editingLine: Int?
    @State private var editedWords = ""
    /// Word by word (`WordTiming`): each line's words and when each is sung.
    @State private var cues: [Int: [WordCue]] = [:]
    /// Asking LRCLIB for lyrics the song has none of, and what came of it.
    @State private var isFindingLyrics = false
    @State private var findNote: String?

    private enum LoadState { case loading, loaded, missing }

    private var player: PlaybackController { appState.player }
    private var lines: [LyricLine] { timing?.lines ?? lyrics?.lines ?? [] }
    private var isSynced: Bool { lyrics?.synced == true }
    /// Whether the lines on screen are of the song playing: not once a song being timed
    /// has ended and the next one begun.
    private var showsPlayingSong: Bool { timing == nil || timingSongID == player.currentSong?.id }
    /// Whether the highlight follows the music.
    private var follows: Bool { showsPlayingSong && (timing?.isTimed ?? isSynced) }

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
        // The words' timing, once the lyrics are on screen: a request of its own, which a
        // song without any answers quickly.
        .task(id: loadedSongID) {
            cues = [:]
            guard let id = loadedSongID, let lyrics, lyrics.synced else { return }
            let offset = lyrics.offset ?? 0
            let sung = lyrics.lines.map { LyricLine(start: $0.start.map { $0 - offset }, value: $0.value) }
            let found = await appState.wordTimings.cues(for: id, lines: sung, sonic: appState.sonic.configuration)
            guard !Task.isCancelled, loadedSongID == id else { return }
            cues = found
        }
        .task(id: ReadAlongRequest(
            songID: loadedSongID,
            romanizes: settings.romanizesLyrics,
            translates: settings.translatesLyrics
        )) {
            // Nothing while a new song's lyrics load: what the read-along holds is still the
            // last song's, and `load()` brings it up to date before they show.
            guard loadedSongID != nil else { return }
            await readAlong.update(romanize: settings.romanizesLyrics)
            await translation.setWanted(settings.translatesLyrics)
        }
        // On the outer view rather than the scroller, which is rebuilt whenever lyrics
        // load; the language-download prompt is presented from here too.
        // `@Sendable` keeps the closure off the main actor, which is where the session
        // has to stay -- see `LyricTranslation.run`.
        .translationTask(translation.configuration) { @Sendable [translation] session in
            await LyricTranslation.run(session, for: translation)
        }
        // The clock is a view of its own, because it reads `elapsed`, which ticks four
        // times a second: read here, it re-ran this body, every line of the lyrics
        // included, on every tick. Out there it re-runs an empty view, and this one runs
        // only when the line changes.
        .background {
            LyricClock(
                lines: lines, isSynced: follows, offset: timing == nil ? lyrics?.offset ?? 0 : 0,
                isTiming: timing != nil
            ) { index in
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
                        Group {
                            if timing == nil, index == activeIndex, let words = cues[index], let start = line.start {
                                SungWords(words: words, start: start - (lyrics?.offset ?? 0))
                            } else {
                                Text(timing != nil && line.value.isEmpty ? "♪" : line.value)
                            }
                        }
                        .font(index == activeIndex
                            ? .title2.weight(.bold)
                            : .title3.weight(.semibold))
                        if timing != nil {
                            // When it starts now, to see what a nudge or a tap did.
                            Text(line.start.map(Self.stamp) ?? "Not timed")
                                .font(.caption.monospacedDigit())
                                .opacity(0.6)
                        }
                        // Beneath the line rather than in its place: the original is
                        // what is being sung, and the highlight stays on it.
                        if timing == nil, settings.romanizesLyrics, let romanized = readAlong.romanized[index] {
                            Text(romanized)
                                .font(index == activeIndex
                                    ? .body.weight(.semibold)
                                    : .callout.weight(.medium))
                                .opacity(0.75)
                        }
                        // Last, and lighter than the romanization: with both on, the
                        // line reads original, then how it sounds, then what it means.
                        if timing == nil, settings.translatesLyrics, let translated = translatedLine(index) {
                            Text(translated)
                                .font(index == activeIndex ? .body : .callout)
                                .opacity(0.6)
                        }
                    }
                    .foregroundStyle(lineColor(for: index))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 20)
                    // The line the next tap times.
                    .background {
                        if timing?.next == index {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(.white.opacity(0.14))
                                .padding(.horizontal, 8)
                        }
                    }
                    .id(index)
                    .contentShape(Rectangle())
                    // While fixing them: a line's words, or the line itself.
                    .contextMenu {
                        if timing != nil {
                            Button("Edit Words", systemImage: "pencil") {
                                editedWords = line.value
                                editingLine = index
                            }
                            Button("Delete Line", systemImage: "trash", role: .destructive) {
                                timing?.delete(index)
                            }
                        }
                    }
                    .onTapGesture {
                        if timing != nil {
                            markLine(index)
                            return
                        }
                        guard isSynced, let start = line.start else { return }
                        // Sung `offset` ms sooner than its stamp: see `LyricClock`.
                        player.seek(to: Double(max(0, start - (lyrics?.offset ?? 0))) / 1000)
                    }
                }

                // Room to bring the last lines up above the timing controls.
                Spacer().frame(height: timing == nil ? 200 : 340)
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: activeIndex)
        }
        // Lines gaining or losing what is beneath them move the line being sung; put it
        // back where the eye expects it.
        .onChange(of: settings.romanizesLyrics) { recentre() }
        .onChange(of: settings.translatesLyrics) { recentre() }
        .onChange(of: readAlong.romanized) { recentre() }
        .onChange(of: translation.lines) { recentre() }
        // Timing by hand, the view keeps the line to tap next in sight.
        .onChange(of: timing?.next) { _, next in
            guard let next, resumeAutoScrollAt.map({ $0 < .now }) ?? true else { return }
            withAnimation(.easeInOut(duration: 0.3)) {
                scrollPosition.scrollTo(id: next, anchor: UnitPoint(x: 0.5, y: 0.32))
            }
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
            VStack(spacing: 4) {
                if timing != nil {
                    Text(showsPlayingSong
                        ? "Tap a line to time it, hold it to change its words"
                        : "This song has ended. Save, or play it again to keep timing.")
                } else if !isSynced {
                    Text("Lyrics not timed")
                }
                if timing == nil, settings.translatesLyrics, let note = translation.note {
                    Text(note)
                }
            }
            .font(.footnote)
            .foregroundStyle(.white.opacity(0.6))
            .padding(.top, 8)
            // Clear of the menu button in the corner.
            .padding(.horizontal, 60)
        }
        .overlay(alignment: .topTrailing) {
            if timing == nil { readAlongMenu }
        }
        .overlay(alignment: .bottom) {
            if let timing { timingControls(timing) }
        }
        .alert("Edit Line", isPresented: Binding(
            get: { editingLine != nil },
            set: { if !$0 { editingLine = nil } }
        )) {
            TextField("Words", text: $editedWords)
            Button("Done") {
                if let editingLine { timing?.edit(editingLine, to: editedWords) }
                editingLine = nil
            }
            Button("Cancel", role: .cancel) { editingLine = nil }
        }
    }

    // MARK: - Timing by hand

    /// Nudges for every line, the tap that times the marked one, and saving.
    private func timingControls(_ timing: LyricsTiming) -> some View {
        VStack(spacing: 12) {
            if let timingError {
                Text(timingError)
                    .font(.footnote)
                    .foregroundStyle(.yellow)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 8) {
                nudgeButton("−0.5", by: -500)
                nudgeButton("−0.1", by: -100)
                Text(Self.shiftLabel(timing.shift))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(maxWidth: .infinity)
                nudgeButton("+0.1", by: 100)
                nudgeButton("+0.5", by: 500)
            }
            .disabled(!timing.isTimed || isSavingTiming)

            Button {
                self.timing?.timeNext(at: Int((player.elapsedNow * 1000).rounded()))
            } label: {
                Label(timing.next == nil ? "Every Line Timed" : "Line Starts Now", systemImage: "hand.tap")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(.white.opacity(0.25))
            .disabled(timing.next == nil || !showsPlayingSong || isSavingTiming)

            HStack {
                Button("Cancel") { endTiming(saved: nil) }
                    .disabled(isSavingTiming)
                Spacer()
                Text(timing.isTimed && !timing.isComplete ? "\(timing.timedCount) of \(timing.lines.count) timed" : "")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                Button {
                    self.timing?.undo()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .accessibilityLabel("Undo")
                .disabled(!timing.canUndo || isSavingTiming)
                if isSavingTiming {
                    ProgressView().padding(.leading, 12)
                } else {
                    Button("Save") { saveTiming() }
                        .fontWeight(.semibold)
                        .padding(.leading, 12)
                        .disabled(!timing.canSave)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .environment(\.colorScheme, .dark)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func nudgeButton(_ title: String, by milliseconds: Int) -> some View {
        Button {
            timing?.nudge(by: milliseconds)
        } label: {
            Text(title)
                .font(.footnote.weight(.semibold).monospacedDigit())
                .frame(minWidth: 44, minHeight: 32)
        }
        .buttonStyle(.bordered)
        .tint(.white)
        .accessibilityLabel(String(
            format: milliseconds > 0 ? "%.1f seconds later" : "%.1f seconds sooner",
            Double(abs(milliseconds)) / 1000
        ))
    }

    private func startTiming() {
        guard let lyrics, let songID = loadedSongID else { return }
        var timing = LyricsTiming(lyrics)
        if timing.wasSynced {
            // The line after the one being sung: the next to come.
            let now = Int(player.elapsedNow * 1000)
            let current = LyricsTiming.current(at: now, in: timing.lines)
            timing.mark(timing.lines.indices.first { $0 > (current ?? -1) && !timing.lines[$0].value.isEmpty })
        }
        timingError = nil
        timingSongID = songID
        self.timing = timing
        resumeAutoScrollAt = nil
    }

    /// A line tapped while timing is marked to be timed next, and one with a time is
    /// played from a moment before it, to tap as it comes.
    private func markLine(_ index: Int) {
        timing?.mark(index)
        guard showsPlayingSong, let start = timing?.lines[index].start else { return }
        player.seek(to: Double(max(0, start - 3000)) / 1000)
    }

    private func saveTiming() {
        guard let timing, let lyrics, let songID = timingSongID else { return }
        isSavingTiming = true
        timingError = nil
        Task {
            do {
                let saved = try await appState.saveLyrics(timing, from: lyrics, songID: songID)
                isSavingTiming = false
                endTiming(saved: saved)
            } catch {
                isSavingTiming = false
                timingError = error.localizedDescription
            }
        }
    }

    /// Back to reading: the saved lyrics, or the song playing now when it has moved on.
    private func endTiming(saved: StructuredLyrics?) {
        let songID = timingSongID
        timing = nil
        timingSongID = nil
        timingError = nil
        activeIndex = nil
        if songID == song.id {
            guard let saved else { return }
            Task { await load(showing: saved) }
        } else {
            Task { await load() }
        }
    }

    /// `0:12.34`.
    private static func stamp(_ milliseconds: Int) -> String {
        let hundredths = milliseconds / 10
        return String(format: "%d:%02d.%02d", hundredths / 6000, hundredths / 100 % 60, hundredths % 100)
    }

    private static func shiftLabel(_ milliseconds: Int) -> String {
        guard milliseconds != 0 else { return "Move all lines" }
        let seconds = String(format: "%.1f", Double(abs(milliseconds)) / 1000)
        return milliseconds > 0 ? "\(seconds) s later" : "\(seconds) s sooner"
    }

    /// Here rather than in Settings: it is wanted song by song, while reading along.
    private var readAlongMenu: some View {
        @Bindable var settings = settings

        return Menu {
            Section {
                Button {
                    startTiming()
                } label: {
                    Label("Fix Lyrics", systemImage: "timer")
                }
            }
            Section {
                Toggle(isOn: $settings.translatesLyrics) {
                    Label("Translate to English", systemImage: "globe")
                }
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

            // LRCLIB, through the service, which saves what it finds beside the song.
            if isFindingLyrics {
                ProgressView()
                    .padding(.top, 8)
                Text("Looking on LRCLIB…")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.6))
            } else {
                Button("Find Lyrics", systemImage: "magnifyingglass") { findLyrics() }
                    .buttonStyle(.bordered)
                    .tint(.white)
                    .padding(.top, 8)
            }
            if let findNote {
                Text(findNote)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
    }

    private func findLyrics() {
        let songID = song.id
        isFindingLyrics = true
        findNote = nil
        Task {
            let answer: SonicClient.FoundLyrics?
            var failure: String?
            do {
                answer = try await appState.findLyrics(songID: songID)
            } catch {
                answer = nil
                failure = error.localizedDescription
            }
            // The song moved on while LRCLIB was asked: the answer is not this one's.
            guard song.id == songID else { return }
            isFindingLyrics = false
            switch answer {
            case let .found(lyrics)?:
                await load(showing: lyrics)
            case .notFound?:
                findNote = "LRCLIB has no lyrics for this recording."
            case .instrumental?:
                findNote = "LRCLIB lists this song as instrumental."
            case nil:
                findNote = failure
            }
        }
    }

    private func translatedLine(_ index: Int) -> String? {
        translation.lines.indices.contains(index) ? translation.lines[index] : nil
    }

    private func recentre() {
        guard shouldAutoScroll, let activeIndex else { return }
        withAnimation(.easeInOut(duration: 0.3)) {
            scrollPosition.scrollTo(id: activeIndex, anchor: UnitPoint(x: 0.5, y: 0.32))
        }
    }

    private func lineColor(for index: Int) -> Color {
        guard let activeIndex else { return .white.opacity(0.5) }
        if index == activeIndex { return .white }
        return .white.opacity(abs(index - activeIndex) >= 3 ? 0.3 : 0.5)
    }

    /// After a touch, once `resumeAutoScrollAt` has passed. Not while the position is the
    /// user's (`isPositionedByUser`): only a scroll from here makes it ours again, and none
    /// was made while it was theirs, so one flick of the lyrics stopped them following for
    /// as long as the screen stayed up, the highlight moving on down out of sight.
    private var shouldAutoScroll: Bool {
        // Timing by hand, the view follows the line to tap next instead, while there is one.
        guard follows, timing?.next == nil else { return false }
        guard let resumeAutoScrollAt else { return true }
        return resumeAutoScrollAt < .now
    }

    /// `showing`: lyrics just saved, shown as they are -- the server has them only once
    /// its watcher has scanned the folder again.
    private func load(showing saved: StructuredLyrics? = nil) async {
        // A song being timed by hand stays on screen when the next one starts, until the
        // timing is saved or given up.
        guard timing == nil else { return }
        state = .loading
        loadedSongID = nil
        isFindingLyrics = false
        findNote = nil
        activeIndex = nil
        resumeAutoScrollAt = nil

        // A downloaded song's own copy, checked against the server once it is on screen.
        var kept: [StructuredLyrics] = []
        if let saved {
            lyrics = saved
        } else {
            // Disk first: for a downloaded track it is already there, and it removes a
            // request plus a visible delay on every track change.
            var sets = await LyricsStore.shared.load(songID: song.id) ?? []
            kept = sets

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
        }

        guard let lyrics, !lyrics.lines.isEmpty else {
            state = .missing
            return
        }

        // Worked out before the lyrics appear, so a romanization, or a translation made
        // on an earlier visit, does not arrive a moment later and push every line down.
        // Only what is quick: a translation still to be made starts once they show.
        readAlong.show(lyrics, songID: song.id)
        await readAlong.update(romanize: settings.romanizesLyrics)
        await translation.prepare(
            songID: song.id,
            lines: lyrics.lines.map(\.value),
            language: readAlong.language,
            wanted: false
        )
        guard !Task.isCancelled else { return }

        state = .loaded
        loadedSongID = song.id
        if !kept.isEmpty { await refreshKept(kept, songID: song.id) }
    }

    /// A downloaded song's lyrics come from the copy saved with it, at once and offline
    /// too; online, the server is asked as well. Lyrics fixed or retimed since the download
    /// take the saved copy's place and come on screen. Without this a downloaded song kept
    /// the lyrics it was downloaded with for good, whatever was fixed on the server.
    private func refreshKept(_ kept: [StructuredLyrics], songID: String) async {
        let server = try? await appState.client.lyrics(songID: songID)
        guard let fresh = LyricsStore.update(kept: kept, server: server) else { return }
        await LyricsStore.shared.save(fresh, for: songID)
        // Not over a song moved on from, or one being timed by hand.
        guard !Task.isCancelled, loadedSongID == songID, timing == nil else { return }
        await load()
    }
}

/// The line being sung, lit word by word as each is sung: the words still to come dimmer.
/// Redrawn by a timeline of its own, a dozen times a second, so only this line is.
private struct SungWords: View {
    @Environment(AppState.self) private var appState
    let words: [WordCue]
    /// When the line is sung, in milliseconds.
    let start: Int

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.08)) { _ in
            let count = WordTiming.sung(words, at: Int(appState.player.elapsedNow * 1000) - start)
            let done = words.prefix(count).map(\.text).joined()
            let rest = words.dropFirst(count).map(\.text).joined()
            Text(done) + Text(rest).foregroundStyle(.white.opacity(0.45))
        }
    }
}

/// What the read-along is asked to bring up to date: the lyrics on screen, and the
/// reader's choices for them.
private struct ReadAlongRequest: Equatable {
    var songID: String?
    var romanizes: Bool
    var translates: Bool
}

/// Which line is being sung, told to the lyrics whenever it changes.
private struct LyricClock: View {
    @Environment(AppState.self) private var appState

    let lines: [LyricLine]
    let isSynced: Bool
    let offset: Int
    /// Lines being timed by hand, some perhaps not yet, which the search below would
    /// trip over.
    var isTiming = false
    let onChange: (Int?) -> Void

    var body: some View {
        Color.clear
            .onChange(of: currentLineIndex) { _, index in onChange(index) }
    }

    /// Binary search rather than a scan: called on every tick.
    private var currentLineIndex: Int? {
        guard isSynced, !lines.isEmpty else { return nil }

        // A positive offset means the lines come *sooner* -- OpenSubsonic's rule, and the
        // LRC `[offset:]` tag's it comes from -- so the clock runs ahead by it. This
        // subtracted it, which made a positive offset come later.
        let now = Int(appState.player.elapsed * 1000) + offset
        if isTiming { return LyricsTiming.current(at: now, in: lines) }
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
