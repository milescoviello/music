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
    }

    private let directory: URL
    private var memory: [String: Entry] = [:]

    init(directory: URL) {
        self.directory = directory
    }

    /// The translation of exactly these lines, if there is one.
    func translations(songID: String, lines: [String]) -> [String?]? {
        guard let entry = memory[songID] ?? read(songID),
              entry.source == lines, entry.translations.count == lines.count
        else { return nil }
        memory[songID] = entry
        return entry.translations
    }

    func save(_ translations: [String?], of lines: [String], songID: String) {
        guard translations.count == lines.count else { return }
        let entry = Entry(source: lines, translations: translations)
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
