import Foundation

/// Lyrics cached beside downloaded audio.
///
/// Fetched when a track is downloaded rather than when it is first played, because
/// offline is precisely when they cannot be fetched — and a downloaded album that
/// loses its lyrics on the train is exactly the kind of half-measure this app is
/// meant to avoid.
///
/// With them, what makes them work as they do online (`DownloadExtras`): when each word is
/// sung, and the desktop's readings for a script it has no tokenizer for. The translation
/// is `LyricTranslationStore`'s, kept in the same folder.
///
/// A singleton, unusually for this codebase, because the download center reaches it
/// from a background relaunch where no `AppState` may exist yet.
actor LyricsStore {
    static let shared = LyricsStore()

    /// Where a song's are kept: with its download, or -- for a song the stream cache holds,
    /// which plays offline too -- in Caches, which iOS may purge along with the song. Read
    /// from either, the download's first.
    enum Place: Sendable {
        case download
        case cache

        var directory: URL { self == .download ? Paths.lyrics : Paths.cachedLyrics }
    }

    func save(_ sets: [StructuredLyrics], for songID: String, in place: Place = .download) {
        guard !sets.isEmpty, let data = try? JSONEncoder().encode(sets) else { return }
        let changed = load(songID: songID) != sets
        try? data.write(to: Paths.lyricsFile(songID: songID, in: place.directory), options: .atomic)
        Self.clearMark(.noLyrics, songID: songID, in: place)
        // New lines may have a translation the old ones had none of.
        if changed { Self.clearMark(.noTranslation, songID: songID, in: place) }
        if place == .cache { trimCache() }
    }

    /// Where this song's lyrics are kept, if anywhere.
    func place(of songID: String) -> Place? {
        if FileManager.default.fileExists(atPath: Paths.lyricsFile(songID: songID).path) { return .download }
        if FileManager.default.fileExists(atPath: Paths.lyricsFile(songID: songID, in: Paths.cachedLyrics).path) { return .cache }
        return nil
    }

    /// A downloaded song's lyrics after `old` was fixed into `new`: the saved copy is what
    /// the app shows before asking the server. Nothing for a song with none kept.
    func replace(_ old: StructuredLyrics, with new: StructuredLyrics, for songID: String) {
        guard let place = place(of: songID), var sets = load(songID: songID) else { return }
        guard let index = sets.firstIndex(of: old) ?? sets.firstIndex(where: {
            $0.synced == old.synced && $0.lines.map(\.value) == old.lines.map(\.value)
        }) else { return }
        sets[index] = new
        save(sets, for: songID, in: place)
    }

    /// What the server answered for a song whose lyrics are kept, when it should take the
    /// kept copy's place: it has lyrics and they differ -- fixed or retimed since the
    /// download. Nil keeps the kept copy: offline, an error, or a server with none, which
    /// is no reason to lose lyrics that work.
    static func update(kept: [StructuredLyrics], server: [StructuredLyrics]?) -> [StructuredLyrics]? {
        guard let server, !server.isEmpty, server != kept else { return nil }
        return server
    }

    func load(songID: String) -> [StructuredLyrics]? {
        for directory in [Paths.lyrics, Paths.cachedLyrics] {
            if let data = try? Data(contentsOf: Paths.lyricsFile(songID: songID, in: directory)),
               let sets = try? JSONDecoder().decode([StructuredLyrics].self, from: data) {
                return sets
            }
        }
        return nil
    }

    /// The cached songs' lyrics, at most `cacheLimit` files: the oldest go. A few KB each,
    /// but one for every song ever cached ahead adds up.
    private var savesSinceTrim = 0
    static let cacheLimit = 6_000

    private func trimCache() {
        savesSinceTrim += 1
        guard savesSinceTrim >= 100 else { return }
        savesSinceTrim = 0
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(at: Paths.cachedLyrics, includingPropertiesForKeys: [.contentModificationDateKey]),
              files.count > Self.cacheLimit else { return }
        let dated = files.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for (file, _) in dated.sorted(by: { $0.1 < $1.1 }).prefix(files.count - Self.cacheLimit) {
            try? manager.removeItem(at: file)
        }
    }

    // MARK: - Word by word

    /// When each word is sung (`WordTiming`), as the service gave it: an empty list for a
    /// song it has no word timing for, so that is not asked again every time.
    func saveWords(_ lines: [SonicClient.WordLine], for songID: String, in place: Place = .download) {
        guard let data = try? JSONEncoder().encode(lines) else { return }
        try? data.write(to: Paths.keptLyricsFile(.words, songID: songID, in: place.directory), options: .atomic)
    }

    func words(songID: String) -> [SonicClient.WordLine]? {
        for directory in [Paths.lyrics, Paths.cachedLyrics] {
            if let data = try? Data(contentsOf: Paths.keptLyricsFile(.words, songID: songID, in: directory)),
               let lines = try? JSONDecoder().decode([SonicClient.WordLine].self, from: data) {
                return lines
            }
        }
        return nil
    }

    // MARK: - Readings

    private struct Readings: Codable {
        /// The lines as they were read.
        var source: [String]
        var tokens: [[Romanizer.Token]]
    }

    /// The desktop's readings of the lines (`SonicClient.readings`), kept with the lines
    /// they are of: lyrics fixed since are read again.
    func saveReadings(_ tokens: [[Romanizer.Token]], of lines: [String], for songID: String, in place: Place = .download) {
        guard tokens.count == lines.count,
              let data = try? JSONEncoder().encode(Readings(source: lines, tokens: tokens)) else { return }
        try? data.write(to: Paths.keptLyricsFile(.readings, songID: songID, in: place.directory), options: .atomic)
    }

    func readings(songID: String, lines: [String]) -> [[Romanizer.Token]]? {
        for directory in [Paths.lyrics, Paths.cachedLyrics] {
            if let data = try? Data(contentsOf: Paths.keptLyricsFile(.readings, songID: songID, in: directory)),
               let kept = try? JSONDecoder().decode(Readings.self, from: data),
               kept.source == lines, kept.tokens.count == lines.count {
                return kept.tokens
            }
        }
        return nil
    }

    // MARK: - What the server had none of

    /// The server had none of this for the song, now: asked again once `retry` has passed,
    /// since lyrics are found and translations made on the server after the download.
    nonisolated static func mark(_ kind: Paths.KeptLyrics, songID: String, in place: Place = .download) {
        try? Data().write(to: Paths.keptLyricsFile(kind, songID: songID, in: place.directory), options: .atomic)
    }

    nonisolated static func clearMark(_ kind: Paths.KeptLyrics, songID: String, in place: Place = .download) {
        try? FileManager.default.removeItem(at: Paths.keptLyricsFile(kind, songID: songID, in: place.directory))
    }

    /// When the server last had none, if it is not yet time to ask again.
    nonisolated static func isMarked(_ kind: Paths.KeptLyrics, songID: String, retry: TimeInterval, now: Date = .now,
                                     in place: Place = .download) -> Bool {
        let file = Paths.keptLyricsFile(kind, songID: songID, in: place.directory)
        guard let marked = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
        else { return false }
        return now.timeIntervalSince(marked) < retry
    }

    /// Asked again after a week: Find Lyrics on another device, or the server's own fill,
    /// gives a song lyrics it had none of.
    static let lyricsRetry: TimeInterval = 7 * 86_400
    /// Whole-song translations are made on the server in batches.
    static let translationRetry: TimeInterval = 3 * 86_400
    /// LRCLIB gains word timing slowly.
    static let wordsRetry: TimeInterval = 30 * 86_400
}

extension StructuredLyrics {
    /// The set the lyrics screens show: a synced one in the reader's language, else any
    /// synced one, else the first. Also what a download keeps translated, so the two agree.
    static func shown(from sets: [StructuredLyrics], language: String? = Locale.preferredLanguages.first) -> StructuredLyrics? {
        let preferred = language?.prefix(2).lowercased() ?? ""
        let synced = sets.filter(\.synced)
        return synced.first { $0.lang?.lowercased().hasPrefix(preferred) == true } ?? synced.first ?? sets.first
    }
}

/// Lyric search with no server: the lines of the lyrics kept on this device that have every
/// word of the query, as the sonic service's search over the library's lyrics finds them.
enum KeptLyricsSearch {
    /// The first matching line of each song, songs in the order given, at most `limit`.
    static func matches(_ query: String, in songs: [(song: Song, lyrics: [StructuredLyrics])], limit: Int = 5) -> [(song: Song, line: String)] {
        let words = WordTiming.key(query).split(separator: " ")
        guard !words.isEmpty, words.joined().count >= 3 else { return [] }
        var found: [(song: Song, line: String)] = []
        for (song, sets) in songs {
            guard let shown = StructuredLyrics.shown(from: sets) else { continue }
            if let line = shown.lines.first(where: { line in
                let lineWords = Set(WordTiming.key(line.value).split(separator: " "))
                return words.allSatisfy(lineWords.contains)
            }) {
                found.append((song, line.value))
                if found.count == limit { break }
            }
        }
        return found
    }
}
