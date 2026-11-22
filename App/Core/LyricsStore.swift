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

    func save(_ sets: [StructuredLyrics], for songID: String) {
        guard !sets.isEmpty, let data = try? JSONEncoder().encode(sets) else { return }
        let changed = load(songID: songID) != sets
        try? data.write(to: Paths.lyricsFile(songID: songID), options: .atomic)
        Self.clearMark(.noLyrics, songID: songID)
        // New lines may have a translation the old ones had none of.
        if changed { Self.clearMark(.noTranslation, songID: songID) }
    }

    /// A downloaded song's lyrics after `old` was fixed into `new`: the saved copy is what
    /// the app shows before asking the server. Nothing for a song with none kept.
    func replace(_ old: StructuredLyrics, with new: StructuredLyrics, for songID: String) {
        guard var sets = load(songID: songID) else { return }
        guard let index = sets.firstIndex(of: old) ?? sets.firstIndex(where: {
            $0.synced == old.synced && $0.lines.map(\.value) == old.lines.map(\.value)
        }) else { return }
        sets[index] = new
        save(sets, for: songID)
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
        guard let data = try? Data(contentsOf: Paths.lyricsFile(songID: songID)),
              let sets = try? JSONDecoder().decode([StructuredLyrics].self, from: data)
        else { return nil }
        return sets
    }

    // MARK: - Word by word

    /// When each word is sung (`WordTiming`), as the service gave it: an empty list for a
    /// song it has no word timing for, so that is not asked again every time.
    func saveWords(_ lines: [SonicClient.WordLine], for songID: String) {
        guard let data = try? JSONEncoder().encode(lines) else { return }
        try? data.write(to: Paths.keptLyricsFile(.words, songID: songID), options: .atomic)
    }

    func words(songID: String) -> [SonicClient.WordLine]? {
        guard let data = try? Data(contentsOf: Paths.keptLyricsFile(.words, songID: songID)) else { return nil }
        return try? JSONDecoder().decode([SonicClient.WordLine].self, from: data)
    }

    // MARK: - Readings

    private struct Readings: Codable {
        /// The lines as they were read.
        var source: [String]
        var tokens: [[Romanizer.Token]]
    }

    /// The desktop's readings of the lines (`SonicClient.readings`), kept with the lines
    /// they are of: lyrics fixed since are read again.
    func saveReadings(_ tokens: [[Romanizer.Token]], of lines: [String], for songID: String) {
        guard tokens.count == lines.count,
              let data = try? JSONEncoder().encode(Readings(source: lines, tokens: tokens)) else { return }
        try? data.write(to: Paths.keptLyricsFile(.readings, songID: songID), options: .atomic)
    }

    func readings(songID: String, lines: [String]) -> [[Romanizer.Token]]? {
        guard let data = try? Data(contentsOf: Paths.keptLyricsFile(.readings, songID: songID)),
              let kept = try? JSONDecoder().decode(Readings.self, from: data),
              kept.source == lines, kept.tokens.count == lines.count
        else { return nil }
        return kept.tokens
    }

    // MARK: - What the server had none of

    /// The server had none of this for the song, now: asked again once `retry` has passed,
    /// since lyrics are found and translations made on the server after the download.
    nonisolated static func mark(_ kind: Paths.KeptLyrics, songID: String) {
        try? Data().write(to: Paths.keptLyricsFile(kind, songID: songID), options: .atomic)
    }

    nonisolated static func clearMark(_ kind: Paths.KeptLyrics, songID: String) {
        try? FileManager.default.removeItem(at: Paths.keptLyricsFile(kind, songID: songID))
    }

    /// When the server last had none, if it is not yet time to ask again.
    nonisolated static func isMarked(_ kind: Paths.KeptLyrics, songID: String, retry: TimeInterval, now: Date = .now) -> Bool {
        let file = Paths.keptLyricsFile(kind, songID: songID)
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
