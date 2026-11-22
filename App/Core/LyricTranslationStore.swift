import Foundation

/// English translations of lyrics, kept so reopening a song's lyrics shows them at once
/// rather than translating again.
///
/// Caches, not Application Support: the phone can always translate them again -- except
/// a downloaded song's, offline, from the server. Those are kept beside its lyrics as well
/// (`keep`), where iOS cannot purge them. Each is kept with the lines it translated, so
/// lyrics that change on the server, or a different set being chosen, are translated
/// afresh instead of shown against the wrong lines.
actor LyricTranslationStore {
    static let shared = LyricTranslationStore(directory: Paths.lyricTranslations, keptDirectory: Paths.lyrics)

    private struct Entry: Codable {
        /// The lines as they were translated.
        var source: [String]
        /// One per line; nil where there was nothing to translate.
        var translations: [String?]
        /// One per line, where a line has wordplay or an idiom the English can't carry; nil
        /// in entries kept before there were notes.
        var notes: [String?]?
        /// What made it: "flash-next" for the server's whole-song translations, which no
        /// on-device or line-by-line one replaces. Nil for the others.
        var engine: String?
    }

    /// A kept translation and what came with it.
    struct Kept: Equatable, Sendable {
        var translations: [String?]
        var notes: [String?]
        var engine: String?

        /// Made from the whole song by the big model on the server: nothing better to ask for.
        var isFinal: Bool { LyricTranslationStore.isWholeSong(engine) }
    }

    /// The engine name the phone keeps its copies of the server's whole-song translations under.
    static let wholeSong = "flash-next"

    /// The engines the server's whole-song translations come from: Flash-Next made the first
    /// ones, Claude has made them since 2026-11-13. Only `flash-next` was accepted before, so
    /// every song Claude translated was thrown away and the phone's own translation shown.
    static let wholeSongEngines: Set<String> = ["flash-next", "claude"]

    static func isWholeSong(_ engine: String?) -> Bool {
        engine.map(wholeSongEngines.contains) ?? false
    }

    private let directory: URL
    /// Downloaded songs' translations, beside their lyrics (`Paths.KeptLyrics.translation`).
    private let keptDirectory: URL?
    private var memory: [String: Entry] = [:]

    init(directory: URL, keptDirectory: URL? = nil) {
        self.directory = directory
        self.keptDirectory = keptDirectory
    }

    /// The translation of exactly these lines, if there is one.
    func translations(songID: String, lines: [String]) -> [String?]? {
        kept(songID: songID, lines: lines)?.translations
    }

    /// The translation of exactly these lines, with its notes, if there is one.
    func kept(songID: String, lines: [String]) -> Kept? {
        func fits(_ entry: Entry?) -> Bool {
            entry.map { $0.source == lines && $0.translations.count == lines.count } ?? false
        }
        // The cache's and the download's can differ: one made before the lyrics were
        // fixed, say, or a cache purged and the download's older.
        var found = memory[songID]
        if !fits(found) { found = [Self.read(file(songID)), keptFile(songID).flatMap(Self.read)].first(where: fits) ?? nil }
        guard let entry = found, fits(entry) else { return nil }
        memory[songID] = entry
        let notes = entry.notes.flatMap { $0.count == lines.count ? $0 : nil } ?? Array(repeating: nil, count: lines.count)
        return Kept(translations: entry.translations, notes: notes, engine: entry.engine)
    }

    /// The translation of exactly these lines kept with the song's download, if there is
    /// one: what offline has, whatever iOS has purged from Caches.
    func keptWithDownload(songID: String, lines: [String]) -> Kept? {
        guard let kept = keptFile(songID).flatMap(Self.read), kept.source == lines,
              kept.translations.count == lines.count else { return nil }
        return Kept(translations: kept.translations,
                    notes: kept.notes.flatMap { $0.count == lines.count ? $0 : nil } ?? Array(repeating: nil, count: lines.count),
                    engine: kept.engine)
    }

    /// `keep`: the song is downloaded, so the translation is kept beside its lyrics too. A
    /// song kept that way stays so: a better translation replaces the kept one as well.
    func save(_ translations: [String?], notes: [String?]? = nil, engine: String? = nil, of lines: [String], songID: String,
              keep: Bool = false) {
        guard translations.count == lines.count, notes.map({ $0.count == lines.count }) ?? true else { return }
        let entry = Entry(source: lines, translations: translations, notes: notes, engine: engine)
        memory[songID] = entry
        guard let data = try? JSONEncoder().encode(entry) else { return }
        try? data.write(to: file(songID), options: .atomic)
        if let kept = keptFile(songID), keep || FileManager.default.fileExists(atPath: kept.path) {
            try? data.write(to: kept, options: .atomic)
        }
    }

    private static func read(_ file: URL) -> Entry? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(Entry.self, from: data)
    }

    private func file(_ songID: String) -> URL {
        directory.appendingPathComponent("\(songID).json")
    }

    private func keptFile(_ songID: String) -> URL? {
        keptDirectory?.appendingPathComponent("\(songID).\(Paths.KeptLyrics.translation.rawValue)")
    }

    // MARK: - Placing a translation under its lines

    /// English for `asked` (the indices of the lines sent), placed under the lines it
    /// translates; nil under a line where it would only repeat it. The one placing for both
    /// lyrics screens and for downloads, so a translation kept ahead of time is the same as
    /// the one the screen would make, and is not made again.
    static func placed(_ english: [String], notes: [String?], asked: [Int], of lines: [String]) -> (lines: [String?], notes: [String?]) {
        var placedLines = [String?](repeating: nil, count: lines.count)
        var placedNotes = [String?](repeating: nil, count: lines.count)
        for (k, index) in asked.enumerated() where k < english.count && lines.indices.contains(index) {
            placedLines[index] = shown(english[k], for: lines[index])
            placedNotes[index] = placedLines[index] == nil ? nil : (notes.indices.contains(k) ? notes[k] : nil)
        }
        return (placedLines, placedNotes)
    }

    /// A translation worth showing under its line, or nil when it would only repeat it:
    /// a name, "la la la", a phrase in English already.
    static func shown(_ translated: String, for original: String) -> String? {
        let trimmed = translated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, comparable(trimmed) != comparable(original) else { return nil }
        return trimmed
    }

    private static func comparable(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }
}
