import Foundation

/// What a download keeps besides its audio, so the song works offline as it does online:
/// its lyrics, the server's translation of them with its notes, when each word is sung,
/// the desktop's readings for a script it has no tokenizer of its own for, and the covers.
///
/// All of that used to be fetched once, when the download was asked for, by a queue held
/// only in memory. iOS suspending or ending the app part-way through a long playlist lost
/// the rest of it; a request that timed out was never made again; and lyrics the server
/// found after the download (its LRCLIB fill, Find Lyrics on another device) never reached
/// it. In the logs of mid-November most downloaded songs played had no lyrics with them,
/// and offline showed "No lyrics" for songs the server had lyrics for all along.
///
/// So every download is swept for what it lacks -- at launch, back in the foreground, when
/// the network returns -- and each piece is asked for until it is kept, or the server says
/// it has none, which is asked again after a while (`LyricsStore`'s retry times). Nothing
/// already here is fetched again, and the audio never is. Two songs at a time; a sweep
/// stops at the first request the server leaves unanswered and carries on once it answers.
@MainActor
final class DownloadExtras {
    private enum Outcome {
        /// Nothing left to ask for now.
        case kept
        /// Something could not be had -- the sonic service down, a song the server refuses:
        /// the next sweep asks again.
        case partly
        /// The music server answered nothing: the sweep stops here.
        case silent
    }

    private struct Tally {
        var lyrics = 0
        var noLyrics = 0
        var words = 0
        var translations = 0
        var readings = 0
        var isEmpty: Bool { lyrics + noLyrics + words + translations + readings == 0 }
    }

    /// The desktop reads some scripts through the service (`SonicClient.readings`); the
    /// phone reads them itself, offline as well.
    #if os(Linux)
    static let readsOnServer = true
    #else
    static let readsOnServer = false
    #endif

    static let concurrency = 2
    /// A sweep that went through every download is not run again for this long: the
    /// retries it would make are days apart.
    static let sweepEvery: TimeInterval = 6 * 3600

    private weak var appState: AppState?
    /// Songs to look at, in turn; new downloads go ahead of what a sweep found.
    private var waiting: [Song] = []
    private var queued: Set<String> = []
    private var running = 0
    /// Looked at this session and lacking nothing: a sweep passes them without reading
    /// their files again.
    private var complete: Set<String> = []
    private var isSweeping = false
    /// Whether the songs queued came from a sweep, which counts as done once they are.
    private var sweepQueued = false
    private var sweptAt: Date?
    /// A sweep the server's silence stopped, to carry on when it answers.
    private var stoppedBySilence = false
    private var tally = Tally()

    func attach(_ appState: AppState) {
        self.appState = appState
    }

    /// Songs just asked to be downloaded, ahead of anything a sweep found.
    func keep(_ songs: [Song]) {
        let new = songs.filter { !queued.contains($0.id) }
        guard !new.isEmpty else { return }
        for song in new {
            queued.insert(song.id)
            complete.remove(song.id)
        }
        waiting.insert(contentsOf: new, at: 0)
        pump()
    }

    /// The server answers again: a sweep it stopped carries on.
    func serverAnswered() {
        if stoppedBySilence { sweep() }
    }

    /// Every download, for what it lacks. Returns at once; cheap when a sweep went through
    /// them all a little while ago.
    func sweep() {
        guard !isSweeping, let appState, appState.credentials != nil else { return }
        if !stoppedBySilence, let sweptAt, Date.now.timeIntervalSince(sweptAt) < Self.sweepEvery { return }
        isSweeping = true
        Task { [weak self] in
            await appState.downloads.catalogLoaded()
            guard let self else { return }
            let catalog = appState.downloads.catalog
            let songs = (Array(catalog.entries.values) + Array(catalog.pending.values)).map(\.song)
            let candidates = songs.filter { !complete.contains($0.id) && !queued.contains($0.id) }
            let readsOnServer = Self.readsOnServer
            // The files of a few hundred songs read and their languages told: off the main actor.
            let lacking = await Task.detached(priority: .utility) {
                var found: [Song] = []
                for song in candidates where await !DownloadLyrics.wants(song.id, readsOnServer: readsOnServer).isEmpty {
                    found.append(song)
                }
                return found
            }.value
            let lackingIDs = Set(lacking.map(\.id))
            for song in candidates where !lackingIDs.contains(song.id) { complete.insert(song.id) }
            stoppedBySilence = false
            isSweeping = false

            if lacking.isEmpty {
                sweptAt = .now
            } else {
                await Diagnostics.shared.record("downloads", "\(lacking.count) of \(songs.count) downloads lack lyrics, "
                    + "their translation or word timing: fetching them")
                sweepQueued = true
                for song in lacking { queued.insert(song.id) }
                waiting.append(contentsOf: lacking)
                pump()
            }
            await keepCovers(of: songs)
        }
    }

    /// Covers for every download, each album's once: a file check for those already kept.
    private func keepCovers(of songs: [Song]) async {
        guard let appState else { return }
        var seen: Set<String> = []
        for song in songs {
            guard let cover = song.coverArt, seen.insert(cover).inserted else { continue }
            // Each would wait out its own timeout; the next sweep tries again.
            if appState.isServerSilent { return }
            await appState.artwork.persistAll(id: cover)
        }
    }

    private func pump() {
        while running < Self.concurrency, !waiting.isEmpty {
            let song = waiting.removeFirst()
            running += 1
            Task(priority: .utility) { [weak self] in
                guard let self else { return }
                let outcome = await keepExtras(of: song)
                finished(song, outcome)
            }
        }
    }

    private func finished(_ song: Song, _ outcome: Outcome) {
        running -= 1
        queued.remove(song.id)
        switch outcome {
        case .kept:
            complete.insert(song.id)
        case .partly:
            break
        case .silent:
            if !stoppedBySilence {
                stoppedBySilence = true
                let left = waiting.count + 1
                Task { await Diagnostics.shared.record("downloads", "the server isn't answering: \(left) downloads' lyrics left for when it does") }
            }
            for left in waiting { queued.remove(left.id) }
            waiting.removeAll()
        }
        guard running == 0, waiting.isEmpty else { return pump() }
        if sweepQueued, !stoppedBySilence { sweptAt = .now }
        sweepQueued = false
        guard !tally.isEmpty else { return }
        let done = tally
        tally = Tally()
        Task {
            await Diagnostics.shared.record("downloads", "kept with downloads: lyrics for \(done.lyrics) "
                + "(\(done.noLyrics) with none on the server), word timing for \(done.words), "
                + "\(done.translations) translations" + (Self.readsOnServer ? ", readings for \(done.readings)" : ""))
        }
    }

    private func keepExtras(of song: Song) async -> Outcome {
        guard let appState, appState.downloads.status(for: song.id) != .none else { return .kept }
        let id = song.id
        // Its covers first: a file check once the album's are kept.
        if !appState.isServerSilent { await appState.artwork.persistAll(id: song.coverArt) }
        var sets = await LyricsStore.shared.load(songID: id) ?? []
        if sets.isEmpty, !LyricsStore.isMarked(.noLyrics, songID: id, retry: LyricsStore.lyricsRetry) {
            do {
                sets = try await appState.client.lyrics(songID: id)
            } catch let error as SubsonicClient.ClientError where error.isTransport {
                return .silent
            } catch {
                return .partly
            }
            // Removed while it was asked for.
            guard appState.downloads.status(for: id) != .none else { return .kept }
            if sets.isEmpty {
                LyricsStore.mark(.noLyrics, songID: id)
                tally.noLyrics += 1
            } else {
                await LyricsStore.shared.save(sets, for: id)
                tally.lyrics += 1
            }
        }

        let wants = await DownloadLyrics.wants(id, readsOnServer: Self.readsOnServer).subtracting(.lyrics)
        guard !wants.isEmpty, let shown = StructuredLyrics.shown(from: sets) else { return .kept }
        guard appState.sonic.isAvailable else { return .partly }
        let sonic = SonicClient(configuration: appState.sonic.configuration)
        let text = shown.lines.map(\.value)
        let language = LyricsLanguage.detect(text, tag: shown.lang)
        var outcome = Outcome.kept

        if wants.contains(.words) {
            do {
                let found = try await sonic.words(songID: id) ?? []
                await LyricsStore.shared.saveWords(found, for: id)
                if !found.isEmpty { tally.words += 1 }
            } catch {
                outcome = .partly
            }
        }

        if wants.contains(.translation) {
            let asked = LyricsLanguage.linesToTranslate(text)
            do {
                // Only one the server has made already: asking for one it has not would set
                // its model going on every downloaded song, opened or not.
                let answer = try await sonic.translate(asked.map { text[$0] }, language: language ?? "", songID: id,
                                                       madeOnly: true)
                // The phone shows the server's whole-song translations and makes its own
                // otherwise; the desktop shows whatever the service made.
                if case let .done(made) = answer, made.isWholeSong || (Self.readsOnServer && !made.draft) {
                    let placed = LyricTranslationStore.placed(made.lines, notes: made.notes, asked: asked, of: text)
                    await LyricTranslationStore.shared.save(placed.lines, notes: placed.notes, engine: made.engine,
                                                            of: text, songID: id, keep: true)
                    tally.translations += 1
                } else {
                    LyricsStore.mark(.noTranslation, songID: id)
                }
            } catch SonicError.notFound {
                LyricsStore.mark(.noTranslation, songID: id)
            } catch {
                outcome = .partly
            }
        }

        if wants.contains(.readings) {
            do {
                let tokens = try await sonic.readings(text)
                await LyricsStore.shared.saveReadings(tokens, of: text, for: id)
                tally.readings += 1
            } catch {
                outcome = .partly
            }
        }
        return outcome
    }
}
