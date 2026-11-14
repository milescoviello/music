import Foundation

/// English translations of lyrics, kept so reopening a song's lyrics shows them at once
/// rather than translating again.
///
/// Caches, not Application Support: the phone can always translate them again. Each is
/// kept with the lines it translated, so lyrics that change on the server, or a different
/// set being chosen, are translated afresh instead of shown against the wrong lines.
actor LyricTranslationStore {
    static let shared = LyricTranslationStore(directory: Paths.lyricTranslations)

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
    private var memory: [String: Entry] = [:]

    init(directory: URL) {
        self.directory = directory
    }

    /// The translation of exactly these lines, if there is one.
    func translations(songID: String, lines: [String]) -> [String?]? {
        kept(songID: songID, lines: lines)?.translations
    }

    /// The translation of exactly these lines, with its notes, if there is one.
    func kept(songID: String, lines: [String]) -> Kept? {
        guard let entry = memory[songID] ?? read(songID),
              entry.source == lines, entry.translations.count == lines.count
        else { return nil }
        memory[songID] = entry
        let notes = entry.notes.flatMap { $0.count == lines.count ? $0 : nil } ?? Array(repeating: nil, count: lines.count)
        return Kept(translations: entry.translations, notes: notes, engine: entry.engine)
    }

    func save(_ translations: [String?], notes: [String?]? = nil, engine: String? = nil, of lines: [String], songID: String) {
        guard translations.count == lines.count, notes.map({ $0.count == lines.count }) ?? true else { return }
        let entry = Entry(source: lines, translations: translations, notes: notes, engine: engine)
        memory[songID] = entry
        guard let data = try? JSONEncoder().encode(entry) else { return }
        try? data.write(to: file(songID), options: .atomic)
    }

    private func read(_ songID: String) -> Entry? {
        guard let data = try? Data(contentsOf: file(songID)) else { return nil }
        return try? JSONDecoder().decode(Entry.self, from: data)
    }

    private func file(_ songID: String) -> URL {
        directory.appendingPathComponent("\(songID).json")
    }
}
