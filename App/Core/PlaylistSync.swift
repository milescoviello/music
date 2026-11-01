import Foundation
import Observation

/// Keeps chosen playlists on the phone automatically.
///
/// **Opt-in, per playlist.** It used to be on for every playlist, which was fine until
/// the library gained Plex's smart playlists: "All Music" alone is every track, and the
/// phone set about downloading the whole library. Now nothing is kept offline until it
/// is chosen in Offline & Library, and smart playlists are never chosen for you.
///
/// Two guard rails, because "download everything" is a big promise on a phone:
///
/// - **Wi-Fi only by default.** 499 tracks of FLAC is roughly 20 GB; that is not
///   something to put on a cellular bill by accident.
/// - **It follows the server, and never deletes what something else wants.** A downloaded
///   playlist is kept as it is on the server: songs added there download, songs taken off
///   leave its download, and its order is the server's. It used to only ever add, so a
///   playlist changed on the desktop was a different playlist on the phone. A song taken
///   off is deleted only if no other downloaded album or playlist has it, and nothing is
///   removed on an answer that looks short -- see `sync`.
@MainActor
@Observable
final class PlaylistSync {
    private enum Key {
        static let enabled = "playlistSync.enabled"
        static let wifiOnly = "playlistSync.wifiOnly"
        static let excluded = "playlistSync.excludedIDs"
        static let included = "playlistSync.includedIDs"
        static let favourites = "playlistSync.favourites"
        /// Set once the opt-in switch-over has run on this phone.
        static let optIn = "playlistSync.optInMigrated"
    }

    /// Default **on**: everything is kept offline unless told otherwise.
    var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Key.enabled) }
    }

    var isWiFiOnly: Bool {
        didSet { UserDefaults.standard.set(isWiFiOnly, forKey: Key.wifiOnly) }
    }

    /// Starred songs are kept too, by the same argument as playlists: they are the
    /// tracks singled out as worth keeping, so "already there" is the right default.
    var includesFavourites: Bool {
        didSet { UserDefaults.standard.set(includesFavourites, forKey: Key.favourites) }
    }

    /// Playlists chosen to keep offline. Stored as ids so renaming one keeps the choice.
    private(set) var includedIDs: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(includedIDs), forKey: Key.included)
        }
    }

    private(set) var isSyncing = false
    /// Last thing it did, for the settings screen.
    private(set) var lastSummary: String?

    private weak var client: SubsonicClient?
    private weak var downloads: DownloadCenter?
    private weak var reachability: Reachability?
    private weak var cache: LibraryCache?
    private weak var folders: DownloadFolderStore?
    @ObservationIgnored private var soon: Task<Void, Never>?

    init() {
        let defaults = UserDefaults.standard
        // `object(forKey:)` rather than `bool(forKey:)`, because a missing key has to
        // mean "on" here and `bool` would report false.
        var migrated = false
        if !defaults.bool(forKey: Key.optIn) {
            // The switch from "every playlist" to "only the ones you choose": off, nothing
            // chosen. Whatever the old default queued is cancelled by `stopUnchosen`.
            defaults.set(false, forKey: Key.enabled)
            defaults.set(false, forKey: Key.favourites)
            defaults.removeObject(forKey: Key.excluded)
            defaults.set(true, forKey: Key.optIn)
            migrated = true
        }
        isEnabled = defaults.object(forKey: Key.enabled) as? Bool ?? false
        isWiFiOnly = defaults.object(forKey: Key.wifiOnly) as? Bool ?? true
        includesFavourites = defaults.object(forKey: Key.favourites) as? Bool ?? false
        includedIDs = Set(defaults.stringArray(forKey: Key.included) ?? [])
        needsStop = migrated
    }

    /// Cancels every download still waiting that was queued for a playlist (or the
    /// favourites) that is not chosen — what the old everything-by-default queued.
    /// Finished downloads are left alone; removing those stays a choice in Downloads.
    func stopUnchosen() {
        guard let downloads else { return }
        let waiting = downloads.catalog.pending.values.filter { entry in
            // An album's download is grouped by its album id: never touched here.
            guard let group = entry.groupID, group != entry.song.albumId else { return false }
            if group == "favourites" { return !(isEnabled && includesFavourites) }
            return !(isEnabled && includedIDs.contains(group))
        }
        guard !waiting.isEmpty else { return }
        downloads.remove(waiting.map(\.song.id))
        lastSummary = "Cancelled \(waiting.count) downloads"
    }

    /// Set by the switch-over, and acted on once the download catalog has loaded.
    @ObservationIgnored private var needsStop = false

    /// Called by `DownloadCenter` once its catalog is loaded.
    func catalogLoaded() {
        guard needsStop else { return }
        needsStop = false
        stopUnchosen()
    }

    func configure(
        client: SubsonicClient,
        downloads: DownloadCenter,
        reachability: Reachability,
        cache: LibraryCache? = nil,
        folders: DownloadFolderStore? = nil
    ) {
        self.client = client
        self.downloads = downloads
        self.reachability = reachability
        self.cache = cache
        self.folders = folders
    }

    /// A sync a few seconds from now: for a playlist just edited here, so its download
    /// follows without waiting for the next launch. Several edits make one sync.
    func syncSoon() {
        soon?.cancel()
        soon = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await self?.sync()
        }
    }

    func isIncluded(_ playlist: Playlist) -> Bool {
        isEnabled && includedIDs.contains(playlist.id)
    }

    func setIncluded(_ included: Bool, for playlist: Playlist) {
        if included {
            includedIDs.insert(playlist.id)
        } else {
            includedIDs.remove(playlist.id)
            // This playlist's waiting downloads only. `stopUnchosen` would also cancel
            // every playlist downloaded with its own button. Waiting songs another
            // download also wants keep coming, for that one.
            guard let downloads else { return }
            let waiting = Set(downloads.catalog.pending.values
                .filter { $0.isMember(of: playlist.id) }
                .map(\.song.id))
            if !waiting.isEmpty { downloads.removeGroup(playlist.id, songIDs: waiting) }
        }
    }

    /// A playlist's download removed with its button: stop syncing it too, or the next
    /// sync would put it all back.
    func stopSyncing(groupID: String) {
        guard includedIDs.contains(groupID) else { return }
        includedIDs.remove(groupID)
    }

    /// Brings every downloaded playlist into line with the server, and downloads the
    /// chosen ones.
    ///
    /// Downloaded means any playlist with songs on the phone for it -- with its own button
    /// or chosen in Offline & Library -- and those are kept in step whether or not the
    /// automatic download is on: that switch is about fetching playlists nobody tapped,
    /// not about letting a downloaded one drift from the server. New songs wait for Wi-Fi
    /// when that is asked for; taking songs off and following the order do not.
    func sync() async {
        guard !isSyncing, let client, let downloads else { return }
        guard reachability?.isOnline != false else { return }
        let mayFetch = !(isWiFiOnly && reachability?.isExpensive == true)

        isSyncing = true
        defer { isSyncing = false }

        guard let playlists = try? await client.playlists() else { return }

        let downloaded = downloads.groups
        var queued = 0
        var dropped = 0
        for playlist in playlists
        where downloaded.contains(playlist.id) || (isEnabled && includedIDs.contains(playlist.id)) {
            guard let detail = try? await client.playlistDetail(id: playlist.id) else { continue }
            let result = follow(detail, name: playlist.name, groupID: playlist.id, mayFetch: mayFetch)
            queued += result.queued
            dropped += result.dropped
            // The Downloads folder takes its order from the cached copy, so it follows the
            // server's order too, offline as well.
            await cache?.store(detail, for: CacheKey.playlist(playlist.id))
            folders?.update(order: detail.songs.map(\.id), forPlaylist: playlist.id)
        }

        if isEnabled, includesFavourites, let starred = try? await client.starred() {
            let favourites = PlaylistDetail(
                id: "favourites", name: "Favourites", songCount: starred.songs.count, entry: starred.songs
            )
            let result = follow(favourites, name: "Favourites", groupID: "favourites", mayFetch: mayFetch)
            queued += result.queued
            dropped += result.dropped
        }

        if queued == 0, dropped == 0 {
            lastSummary = mayFetch ? "Everything is on this phone" : "Waiting for Wi-Fi"
        } else {
            lastSummary = [
                queued > 0 ? "Downloading \(queued) \(queued == 1 ? "track" : "tracks")" : nil,
                dropped > 0 ? "\(dropped) taken off" : nil,
            ].compactMap { $0 }.joined(separator: " · ")
        }
        if queued > 0 || dropped > 0 {
            await Diagnostics.shared.record("playlist sync", "queued \(queued), dropped \(dropped)")
        }
    }

    /// One playlist's download, made the server's: its songs already on the phone for
    /// another reason join it, missing ones download when `mayFetch`, and ones the server
    /// no longer has leave it -- deleted only if nothing else wants them.
    ///
    /// Nothing leaves on an answer that looks short -- fewer songs than the playlist says
    /// it has, or none at all -- because deleting on a bad answer is the one mistake here
    /// that costs music.
    private func follow(
        _ detail: PlaylistDetail, name: String, groupID: String, mayFetch: Bool
    ) -> (queued: Int, dropped: Int) {
        guard let downloads else { return (0, 0) }
        let songs = detail.songs
        let missing = songs.filter { downloads.status(for: $0.id) == .none }.count
        if mayFetch {
            downloads.download(songs, groupID: groupID, groupName: name)
        } else {
            // Join only: what is already here becomes part of it, nothing is fetched.
            downloads.download(songs.filter { downloads.status(for: $0.id) != .none }, groupID: groupID, groupName: name)
        }

        let isWhole = !songs.isEmpty && (detail.songCount.map { $0 == songs.count } ?? true)
        guard isWhole else { return (mayFetch ? missing : 0, 0) }
        let onServer = Set(songs.map(\.id))
        let stale = Set(downloads.catalog.songIDs(downloadedAs: groupID)).subtracting(onServer)
        if !stale.isEmpty { downloads.removeGroup(groupID, songIDs: stale) }
        return (mayFetch ? missing : 0, stale.count)
    }

    /// Rough projection for the settings screen, so 20 GB is never a surprise.
    ///
    /// Uses the playlists' own reported durations rather than fetching every track, and
    /// the rate measured from the files already on the phone rather than the 1 MB/s this
    /// used to assume — that figure is only correct for 16-bit 44.1 kHz FLAC.
    func estimatedSize(for playlists: [Playlist], bytesPerSecond: Double = 1_000_000) -> Int64 {
        let seconds = playlists
            .filter { includedIDs.contains($0.id) }
            .reduce(0) { $0 + ($1.duration ?? 0) }
        return Int64(Double(seconds) * bytesPerSecond)
    }
}
