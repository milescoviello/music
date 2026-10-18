import Foundation

/// How much of a file to fetch.
///
/// `original` is the point of this app — the FLAC, byte for byte — and stays the default
/// everywhere. The transcoded rungs exist for the one case where that does not fit: five
/// days away from a network is roughly 54 GB of FLAC and 1.7 GB at 256 kbps.
///
/// The server does the work, through `stream.view?format=mp3&maxBitRate=`. That is the
/// same path already used for containers iOS cannot decode, not a second mechanism —
/// which is why a quality choice cannot go wrong in a way original downloads don't.
enum DownloadQuality: String, Codable, Sendable, CaseIterable, Identifiable {
    case original
    case high
    case standard
    case small

    var id: String { rawValue }

    /// Nil for `original`, which is a `download.view` of the stored file.
    var maxBitRate: Int? {
        switch self {
        case .original: return nil
        case .high: return 320
        case .standard: return 256
        case .small: return 128
        }
    }

    var label: String {
        switch self {
        case .original: return "Original"
        case .high: return "High"
        case .standard: return "Standard"
        case .small: return "Small"
        }
    }

    var detail: String {
        switch self {
        case .original: return "Lossless, as stored on the server"
        case .high: return "320 kbps MP3"
        case .standard: return "256 kbps MP3"
        case .small: return "128 kbps MP3"
        }
    }

    /// What one song is expected to occupy.
    ///
    /// Exact for `original`, because Navidrome populates `size`. For the transcoded rungs
    /// it is bitrate × duration, which is close enough to plan a trip around and the only
    /// figure available before the bytes arrive — the real size replaces it the moment the
    /// transfer finishes.
    func estimatedBytes(for song: Song) -> Int64 {
        guard let maxBitRate else { return Int64(song.size ?? 0) }
        let seconds = song.duration ?? 0
        return Int64(seconds) * Int64(maxBitRate) * 1_000 / 8
    }
}

/// What is on this phone.
///
/// Plain JSON on disk rather than SwiftData, for one decisive reason: this is written
/// from a background `URLSession` delegate in a process iOS relaunched with no UI,
/// possibly before first unlock. A versioned file that can be dumped, diffed and
/// hand-repaired is worth more than object-graph ergonomics for a couple of thousand
/// rows -- especially with CI as the only compiler and no debugger on the device.
struct DownloadCatalog: Codable, Sendable {
    /// Bumped only for a breaking change; a stale version is discarded rather than
    /// migrated, because the audio files themselves are the real data and can be
    /// re-adopted from disk.
    static let currentVersion = 1

    var version = currentVersion
    /// Keyed by song id.
    var entries: [String: Entry] = [:]
    /// Downloads that have been started but not finished, keyed by song id. Written
    /// **before** the transfer starts, so a kill mid-download leaves enough on disk
    /// to either resume or reconcile.
    var pending: [String: Entry] = [:]

    struct Entry: Codable, Sendable, Identifiable {
        /// The whole song, not a reference: offline browse must not need the server.
        var song: Song
        /// Relative to `Paths.media`, so the container path moving between iOS
        /// versions cannot invalidate the catalog.
        var filename: String
        var byteCount: Int64
        var addedAt: Date
        /// The album or playlist this was downloaded as part of, for grouping in the
        /// Downloads screen. Nil for a single song.
        var groupID: String?
        var groupName: String?
        /// `DownloadQuality.rawValue`. Optional, and read through `quality` below, because
        /// every file downloaded before this existed has no such key — and a
        /// non-optional with a default would make the whole catalog undecodable, which is
        /// the bug this batch went looking for in `ServerOutbox`.
        var qualityRaw: String?

        var quality: DownloadQuality {
            qualityRaw.flatMap(DownloadQuality.init(rawValue:)) ?? .original
        }

        var id: String { song.id }
        var url: URL { Paths.media.appendingPathComponent(filename) }
    }

    var totalBytes: Int64 {
        entries.values.reduce(0) { $0 + $1.byteCount }
    }

    /// What one album's or playlist's download is: the songs here or on their way under
    /// `groupID`, and — for an album, whose group id is its album id — the songs of it
    /// downloaded one at a time, which the Downloads screen files in the album's folder
    /// too. Songs that came with some other album or playlist are not in it: removing
    /// this download must not take tracks another one still shows.
    func songIDs(downloadedAs groupID: String) -> [String] {
        [entries, pending].flatMap { table in
            table.values.lazy
                .filter { $0.groupID == groupID || ($0.groupID == nil && $0.song.albumId == groupID) }
                .map(\.song.id)
        }
    }

    /// The albums represented by what is downloaded, newest addition first.
    ///
    /// Reconstructed from the catalog rather than filtered out of a server page. Filtering
    /// a 100-album page down to the handful that are downloaded can easily yield zero
    /// rows, which stalls a sentinel-paged list on an empty screen forever — the list
    /// never asks for page two because nothing came into view.
    var downloadedAlbums: [Album] {
        var byAlbum: [String: (album: Album, addedAt: Date, count: Int)] = [:]

        for entry in entries.values {
            let song = entry.song
            let id = song.albumId ?? "album-\(song.album ?? song.id)"
            if var existing = byAlbum[id] {
                existing.count += 1
                existing.addedAt = max(existing.addedAt, entry.addedAt)
                byAlbum[id] = existing
            } else {
                byAlbum[id] = (
                    Album(
                        id: id,
                        name: song.album ?? "Unknown Album",
                        artist: song.artist,
                        coverArt: song.coverArt,
                        songCount: 1,
                        year: song.year
                    ),
                    entry.addedAt,
                    1
                )
            }
        }

        return byAlbum.values
            .sorted { $0.addedAt > $1.addedAt }
            .map { item in
                var album = item.album
                album.songCount = item.count
                return album
            }
    }

    /// Bytes per second of audio, measured from what is actually on this phone.
    ///
    /// Projections used to assume 1 MB/s, which is right for 16-bit 44.1 kHz FLAC and
    /// wrong for everything else in a library that also holds 24/96 and MP3. Measuring
    /// costs nothing — the sizes and durations are already here — and it self-corrects as
    /// the mix of what is downloaded changes. Transcoded copies are excluded so a few
    /// small files cannot drag the estimate for a lossless download down with them.
    var measuredBytesPerSecond: Double {
        var bytes = 0.0
        var seconds = 0.0
        for entry in entries.values where entry.quality == .original {
            guard let duration = entry.song.duration, duration > 0, entry.byteCount > 0 else { continue }
            bytes += Double(entry.byteCount)
            seconds += Double(duration)
        }
        // Nothing downloaded yet: fall back to the old figure rather than to zero.
        guard seconds > 60 else { return 1_000_000 }
        return bytes / seconds
    }
}

/// Owns the catalog file. An actor because the download delegate, the UI and the
/// launch-time reconcile all touch it.
actor DownloadCatalogStore {
    private let url: URL
    private var catalog = DownloadCatalog()
    private var isLoaded = false

    init(url: URL = Paths.catalog) {
        self.url = url
    }

    func load() -> DownloadCatalog {
        guard !isLoaded else { return catalog }
        isLoaded = true

        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(DownloadCatalog.self, from: data),
              decoded.version == DownloadCatalog.currentVersion
        else {
            // Nothing, corrupt, or from a future build: start clean and let
            // `reconcile` re-adopt whatever audio is actually on disk.
            catalog = DownloadCatalog()
            return catalog
        }

        catalog = decoded
        return catalog
    }

    func markPending(_ entry: DownloadCatalog.Entry) -> DownloadCatalog {
        markPending([entry])
    }

    /// A whole album or playlist in one write. One call per song re-encoded the whole
    /// catalog per song — a long playlist was minutes of it — and the button read
    /// "not downloading" for every song still waiting its turn.
    func markPending(_ entries: [DownloadCatalog.Entry]) -> DownloadCatalog {
        _ = load()
        for entry in entries {
            catalog.pending[entry.song.id] = entry
        }
        save()
        return catalog
    }

    /// Promotes a pending entry once its file is in place.
    func complete(songID: String, byteCount: Int64) -> DownloadCatalog {
        _ = load()
        guard var entry = catalog.pending.removeValue(forKey: songID) else { return catalog }
        entry.byteCount = byteCount
        entry.addedAt = .now
        catalog.entries[songID] = entry
        save()
        return catalog
    }

    func cancelPending(songID: String) -> DownloadCatalog {
        _ = load()
        catalog.pending.removeValue(forKey: songID)
        save()
        return catalog
    }

    func remove(songIDs: [String]) -> DownloadCatalog {
        _ = load()
        for id in songIDs {
            if let entry = catalog.entries.removeValue(forKey: id) {
                try? FileManager.default.removeItem(at: entry.url)
            }
            catalog.pending.removeValue(forKey: id)
            try? FileManager.default.removeItem(at: Paths.lyricsFile(songID: id))
        }
        save()
        return catalog
    }

    func removeAll() -> DownloadCatalog {
        _ = load()
        catalog = DownloadCatalog()
        save()

        // The directory is the truth for storage, so clear it wholesale rather than
        // per entry -- that also sweeps up anything the catalog had lost track of.
        for directory in [Paths.media, Paths.incoming, Paths.lyrics] {
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil
            )) ?? []
            for file in contents where file.hasDirectoryPath == false {
                try? FileManager.default.removeItem(at: file)
            }
        }
        return catalog
    }

    /// Reality check against the filesystem, run once at launch.
    ///
    /// Two directions, both of which happen for real:
    /// - An entry whose file is gone (restored device, manual clear) is dropped.
    /// - A pending entry whose file *is* on disk is promoted. That is the crash
    ///   window between the delegate's move and the catalog write; without this the
    ///   download would appear to have failed while occupying storage.
    /// A small file starting with a JSON or XML envelope: an error, not audio.
    static func isErrorBody(_ url: URL) -> Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard size < 8_192, let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 64) else { return false }
        let text = String(decoding: head, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.hasPrefix("{") || text.hasPrefix("<")
    }

    func reconcile() -> DownloadCatalog {
        _ = load()
        var changed = false

        for (id, entry) in catalog.entries {
            if !FileManager.default.fileExists(atPath: entry.url.path) {
                catalog.entries.removeValue(forKey: id)
                changed = true
            } else if Self.isErrorBody(entry.url) {
                // A server error saved as a track (see `DownloadSessionDelegate`): it
                // would "play" as silence, so it goes, and the song can be fetched again.
                try? FileManager.default.removeItem(at: entry.url)
                catalog.entries.removeValue(forKey: id)
                changed = true
            }
        }

        for (id, entry) in catalog.pending {
            let attributes = try? FileManager.default.attributesOfItem(atPath: entry.url.path)
            guard let size = (attributes?[.size] as? NSNumber)?.int64Value, size > 0 else {
                continue
            }

            var promoted = entry
            promoted.byteCount = size
            promoted.addedAt = .now
            catalog.pending.removeValue(forKey: id)
            catalog.entries[id] = promoted
            changed = true
        }

        // Staged files never survive a relaunch: the URLSession temp file they were
        // being written from is gone, so they can only be dead weight.
        let staged = (try? FileManager.default.contentsOfDirectory(
            at: Paths.incoming, includingPropertiesForKeys: nil
        )) ?? []
        for file in staged {
            try? FileManager.default.removeItem(at: file)
        }

        if changed { save() }
        return catalog
    }

    /// Atomic, so a kill mid-write cannot leave a half-written catalog that fails to
    /// decode and takes the whole library's index with it.
    private func save() {
        guard let data = try? JSONEncoder().encode(catalog) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
