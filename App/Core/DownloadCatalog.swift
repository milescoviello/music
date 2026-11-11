import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

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
        /// Every album and playlist this song is on the phone for, read through
        /// `memberships`. Optional for the same reason as `qualityRaw`: catalogs from
        /// before it have only `groupID`, which reads as a list of one.
        ///
        /// A song used to have one group, the first download that brought it. Downloading
        /// a second playlist skipped the songs already here, so they never joined it --
        /// that playlist's folder lacked them -- and removing the first playlist deleted
        /// them although the second still had them.
        var memberships_: [Membership]?

        var quality: DownloadQuality {
            qualityRaw.flatMap(DownloadQuality.init(rawValue:)) ?? .original
        }

        var id: String { song.id }
        var url: URL { Paths.media.appendingPathComponent(filename) }

        /// Why this song is here: the albums and playlists it came with, and `.own` when it
        /// was downloaded by itself. Setting it keeps `groupID` and `groupName` as the
        /// first group's, for anything that still reads those.
        var memberships: [Membership] {
            get {
                memberships_ ?? [groupID.map { Membership(id: $0, name: groupName) } ?? .own]
            }
            set {
                memberships_ = newValue
                let first = newValue.first { !$0.isOwn }
                groupID = first?.id
                groupName = first?.name
            }
        }

        /// In this album's or playlist's download. A song downloaded by itself counts as
        /// part of its own album's, which is where the Downloads screen files it.
        func isMember(of groupID: String) -> Bool {
            memberships.contains { $0.id == groupID || ($0.isOwn && song.albumId == groupID) }
        }

        /// Takes this song out of one album's or playlist's download. Nil when nothing
        /// else wants it, meaning its file can go.
        func leaving(_ groupID: String) -> Entry? {
            let rest = memberships.filter { !($0.id == groupID || ($0.isOwn && song.albumId == groupID)) }
            guard !rest.isEmpty else { return nil }
            var entry = self
            entry.memberships = rest
            return entry
        }

        /// This song, in one more album's or playlist's download as well.
        func joining(_ membership: Membership) -> Entry {
            guard !memberships.contains(where: { $0.id == membership.id }) else { return self }
            var entry = self
            entry.memberships = memberships + [membership]
            return entry
        }
    }

    /// One reason a song is downloaded.
    struct Membership: Codable, Sendable, Hashable {
        /// The album or playlist id; empty for a song downloaded by itself.
        var id: String
        var name: String?

        static let own = Membership(id: "", name: nil)
        var isOwn: Bool { id.isEmpty }
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
                .filter { $0.isMember(of: groupID) }
                .map(\.song.id)
        }
    }

    /// Ends one album's or playlist's download, for `songIDs` or for all its songs. A song
    /// another download still has stays here and only leaves this one; the rest are taken
    /// out and returned, so their files and transfers can follow.
    mutating func leave(
        _ groupID: String,
        songIDs: Set<String>? = nil
    ) -> (finished: [Entry], waiting: [Entry]) {
        func sweep(_ table: inout [String: Entry]) -> [Entry] {
            var gone: [Entry] = []
            for (id, entry) in table where entry.isMember(of: groupID) && (songIDs?.contains(id) ?? true) {
                if let staying = entry.leaving(groupID) {
                    table[id] = staying
                } else {
                    table.removeValue(forKey: id)
                    gone.append(entry)
                }
            }
            return gone
        }
        return (sweep(&entries), sweep(&pending))
    }

    /// These songs, already here or on their way, in one more download as well.
    mutating func join(songIDs: [String], _ membership: Membership) -> Bool {
        var changed = false
        for id in songIDs {
            if let entry = entries[id] {
                let joined = entry.joining(membership)
                if joined.memberships != entry.memberships { entries[id] = joined; changed = true }
            } else if let entry = pending[id] {
                let joined = entry.joining(membership)
                if joined.memberships != entry.memberships { pending[id] = joined; changed = true }
            }
        }
        return changed
    }

    /// Every album and playlist id with something downloaded or on its way.
    var groupIDs: Set<String> {
        var ids = Set<String>()
        for table in [entries, pending] {
            for entry in table.values {
                for membership in entry.memberships where !membership.isOwn { ids.insert(membership.id) }
            }
        }
        return ids
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

    /// What an album's or playlist's download button shows, for its songs `songIDs`.
    ///
    /// Only its own download counts: `asked` says one was just asked for, before its
    /// waiting songs are written here. Songs it shares with another download still
    /// arriving used to make its button that download's ring, and tapping the ring took
    /// away a download it never had, so a second playlist could not be downloaded until
    /// the first was done. Not downloaded as itself, it is `.none` whatever is on the
    /// device, and a tap downloads it, taking in the songs already here or on their way.
    func collectionState(
        of songIDs: [String],
        groupID: String,
        progress: [String: Double],
        asked: Bool
    ) -> CollectionDownloadState {
        guard !songIDs.isEmpty else { return .none }
        let isOwn = asked || songIDs.contains { id in
            (entries[id] ?? pending[id])?.isMember(of: groupID) == true
        }
        guard isOwn else { return .none }

        var downloaded = 0
        var arriving = 0
        var transferred = 0.0
        for id in songIDs {
            if entries[id] != nil {
                downloaded += 1
            } else if let fraction = progress[id] {
                arriving += 1
                transferred += fraction
            } else if pending[id] != nil {
                arriving += 1
            }
        }
        if arriving > 0 {
            // Across the whole collection, counting the songs already here: otherwise the
            // ring jumps backwards at every song.
            return .working(fraction: (Double(downloaded) + transferred) / Double(songIDs.count))
        }
        return downloaded == songIDs.count ? .complete : .none
    }
}

/// An album's or playlist's download button.
enum CollectionDownloadState: Equatable, Sendable {
    /// Not downloaded as itself, or only partly with nothing arriving: a tap downloads
    /// whatever is missing.
    case none
    case working(fraction: Double)
    case complete

    var isOn: Bool { self != .none }
}

/// Owns the catalog file. An actor because the download delegate, the UI and the
/// launch-time reconcile all touch it.
///
/// Every change is written at once except one: a finished song. The file is the whole
/// catalog — every downloaded song with all its metadata — so writing it per finished
/// song made an album download a long run of full-catalog encodes. Those are gathered and
/// written a second after the first of them, and at once when the app goes to the
/// background (`flush()`) or anything else changes the catalog.
///
/// Holding a finished song back is safe because of what is written at once: the song is
/// recorded as pending before its transfer starts (`markPending`), and the delegate moves
/// its file into place before `complete` is called. So a kill before the write leaves a
/// pending entry whose file is on disk, which is exactly what `reconcile()` promotes at the
/// next launch, with the file's real size. Nothing is lost in that window, as nothing was
/// before; the song is promoted at launch rather than having been promoted already.
actor DownloadCatalogStore {
    private let url: URL
    private var catalog = DownloadCatalog()
    private var isLoaded = false
    /// The write gathering finished songs, while one is due.
    private var pendingSave: Task<Void, Never>?
    /// How long finished songs are gathered for.
    private let completionDelay: Duration

    init(url: URL = Paths.catalog, completionDelay: Duration = .seconds(1)) {
        self.url = url
        self.completionDelay = completionDelay
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
        saveSoon()
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

    /// Takes these songs, already here or on their way, into one more download as well.
    func join(songIDs: [String], _ membership: DownloadCatalog.Membership) -> DownloadCatalog {
        _ = load()
        if catalog.join(songIDs: songIDs, membership) { save() }
        return catalog
    }

    /// Ends one album's or playlist's download: see `DownloadCatalog.leave`. Deletes the
    /// files of the songs nothing else wants, and returns their ids so their transfers
    /// can be cancelled.
    func leave(
        _ groupID: String,
        songIDs: Set<String>? = nil
    ) -> (catalog: DownloadCatalog, removed: [String]) {
        _ = load()
        let gone = catalog.leave(groupID, songIDs: songIDs)
        for entry in gone.finished {
            try? FileManager.default.removeItem(at: entry.url)
            try? FileManager.default.removeItem(at: Paths.lyricsFile(songID: entry.song.id))
        }
        save()
        return (catalog, (gone.finished + gone.waiting).map(\.song.id))
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

    /// Writes whatever finished songs are waiting to be written. For going to the
    /// background, where the process may not come back.
    func flush() {
        guard pendingSave != nil else { return }
        save()
    }

    /// Finished songs, written together: see the type's comment for why that is safe.
    private func saveSoon() {
        guard pendingSave == nil else { return }
        let delay = completionDelay
        pendingSave = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self.save()
        }
    }

    /// Atomic, so a kill mid-write cannot leave a half-written catalog that fails to
    /// decode and takes the whole library's index with it. Writes the whole catalog, so
    /// it also writes any finished songs that were waiting.
    private func save() {
        pendingSave?.cancel()
        pendingSave = nil
        guard let data = try? JSONEncoder().encode(catalog) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
