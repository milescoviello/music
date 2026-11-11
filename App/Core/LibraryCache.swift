import Foundation

/// Last-known copies of everything the library screens display.
///
/// This is what lets the normal routes work with the server switched off. Playlists,
/// albums and artists are cached to disk whenever they are successfully fetched, and
/// served from disk when a fetch fails — so Library → Playlists → tap → play behaves the
/// same offline as on, rather than being a special "Downloads" mode the user has to
/// remember exists.
///
/// Deliberately a *fallback* rather than a read-through cache: online, the server is
/// always asked and always wins, because stars and play counts change from the desktop
/// client too. Stale data is only ever shown when the alternative is nothing.
actor LibraryCache {
    private let directory: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(directory: URL = Paths.metadata) {
        self.directory = directory
    }

    /// Fetches, caches on success, falls back to the cache on failure.
    ///
    /// Returns the value and whether it came from disk, because a screen showing
    /// month-old data should be able to say so.
    func value<T: Codable & Sendable>(
        for key: String,
        fetch: @Sendable () async throws -> T
    ) async -> (value: T?, isStale: Bool) {
        do {
            let fresh = try await fetch()
            store(fresh, for: key)
            return (fresh, false)
        } catch {
            // Given up on by its caller -- a screen closed mid-load -- rather than failed:
            // the saved copy, if anything wants it, but not "the server didn't answer".
            // Counted as stale, a page left before it loaded had the whole app saying
            // "Offline" (2026-11-08).
            let wasCancelled = Task.isCancelled || error is CancellationError
                || (error as NSError).code == NSURLErrorCancelled
            return (load(T.self, for: key), !wasCancelled)
        }
    }

    func store<T: Encodable>(_ value: T, for key: String) {
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url(for: key), options: .atomic)
    }

    func load<T: Decodable>(_ type: T.Type, for key: String) -> T? {
        guard let data = try? Data(contentsOf: url(for: key)) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    func clear() {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        for file in contents {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Keys become filenames, so anything that could appear in an id — slashes in a
    /// path-style id, colons — has to go.
    private func url(for key: String) -> URL {
        let safe = key.unicodeScalars.map { scalar -> String in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "."
                ? String(scalar)
                : "_"
        }.joined()
        return directory.appendingPathComponent("\(safe).json")
    }
}

/// Cache keys in one place, so a typo cannot silently create a second cache entry that
/// is never read.
enum CacheKey {
    static let playlists = "playlists"
    static let musicFolders = "musicFolders"

    static func playlist(_ id: String) -> String { "playlist-\(id)" }
    static func album(_ id: String) -> String { "album-\(id)" }
    static func artist(_ id: String) -> String { "artist-\(id)" }
    static func artistSongs(_ id: String) -> String { "artist-songs-\(id)" }
    static func albumList(_ sort: String, _ scope: String) -> String {
        "albums-\(sort)-\(scope)"
    }
    static func artistIndex(_ scope: String) -> String { "artists-\(scope)" }
    static func genres(_ scope: String) -> String { "genres-\(scope)" }
    static func starred(_ scope: String) -> String { "starred-\(scope)" }
    static func shelf(_ name: String, _ scope: String) -> String { "shelf-\(name)-\(scope)" }
}
