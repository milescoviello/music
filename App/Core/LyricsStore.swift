import Foundation

/// Lyrics cached beside downloaded audio.
///
/// Fetched when a track is downloaded rather than when it is first played, because
/// offline is precisely when they cannot be fetched — and a downloaded album that
/// loses its lyrics on the train is exactly the kind of half-measure this app is
/// meant to avoid.
///
/// A singleton, unusually for this codebase, because the download center reaches it
/// from a background relaunch where no `AppState` may exist yet.
actor LyricsStore {
    static let shared = LyricsStore()

    func save(_ sets: [StructuredLyrics], for songID: String) {
        guard !sets.isEmpty, let data = try? JSONEncoder().encode(sets) else { return }
        try? data.write(to: Paths.lyricsFile(songID: songID), options: .atomic)
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
}
