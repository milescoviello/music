import Foundation

/// What a cached or streamed file is: the stored original, or a server transcode.
enum StreamVariant: Codable, Hashable, Sendable {
    case original
    case mp3(kbps: Int)

    /// Whether a file of this variant can stand in for a request for `wanted`.
    ///
    /// The original satisfies anything, and a transcode satisfies any request for the
    /// same rate or lower: a 320 kbps file already on the phone is a better answer to
    /// "128 kbps, please" than fetching the 128 kbps one. Never the other way — a cached
    /// 128 kbps file must not quietly stand in for the original on Wi-Fi.
    func satisfies(_ wanted: StreamVariant) -> Bool {
        switch (self, wanted) {
        case (.original, _): return true
        case (.mp3, .original): return false
        case let (.mp3(have), .mp3(want)): return have >= want
        }
    }

    var fileExtension: String? {
        switch self {
        case .original: return nil
        case .mp3: return "mp3"
        }
    }
}

/// What the stream cache holds: one file per song, used least-recently-first.
///
/// The bookkeeping half of Plexamp's "cache ahead" — Foundation-only so its two rules
/// can be tested: a request is answered by any variant at least as good, and eviction
/// takes the stalest files first and never one that is about to play.
struct StreamCacheIndex: Codable, Sendable {
    struct Entry: Codable, Hashable, Sendable {
        let songID: String
        var variant: StreamVariant
        var fileName: String
        var bytes: Int64
        var lastUsed: Date
    }

    private(set) var entries: [String: Entry] = [:]

    var totalBytes: Int64 { entries.values.reduce(0) { $0 + $1.bytes } }

    func entry(for songID: String, satisfying wanted: StreamVariant) -> Entry? {
        guard let entry = entries[songID], entry.variant.satisfies(wanted) else { return nil }
        return entry
    }

    mutating func touch(_ songID: String, at date: Date = .now) {
        entries[songID]?.lastUsed = date
    }

    /// Adds or replaces the file for a song. Returns the entry it replaced, whose file
    /// the caller must delete if its name differs.
    @discardableResult
    mutating func insert(_ entry: Entry) -> Entry? {
        let previous = entries[entry.songID]
        entries[entry.songID] = entry
        return previous
    }

    @discardableResult
    mutating func remove(_ songID: String) -> Entry? {
        entries.removeValue(forKey: songID)
    }

    mutating func removeAll() {
        entries.removeAll()
    }

    /// The entries to delete to get under `maxBytes`, stalest first.
    ///
    /// `protected` — the current track and the ones cached ahead of it — is never
    /// offered, even if that leaves the cache over its limit: evicting a track a few
    /// minutes before it plays would only mean fetching it again.
    func evictions(toFit maxBytes: Int64, protecting protected: Set<String>) -> [Entry] {
        var total = totalBytes
        guard total > maxBytes else { return [] }

        var chosen: [Entry] = []
        for entry in entries.values.sorted(by: { $0.lastUsed < $1.lastUsed })
        where !protected.contains(entry.songID) {
            guard total > maxBytes else { break }
            chosen.append(entry)
            total -= entry.bytes
        }
        return chosen
    }
}
