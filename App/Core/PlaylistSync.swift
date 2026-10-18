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
/// - **It only ever adds.** A track dropped from a playlist keeps its download rather
///   than being deleted, because the alternative is an automatic process quietly
///   removing music someone may have wanted. Reclaiming space stays a manual choice in
///   the Downloads screen.
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
        reachability: Reachability
    ) {
        self.client = client
        self.downloads = downloads
        self.reachability = reachability
    }

    func isIncluded(_ playlist: Playlist) -> Bool {
        isEnabled && includedIDs.contains(playlist.id)
    }

    func setIncluded(_ included: Bool, for playlist: Playlist) {
        if included {
            includedIDs.insert(playlist.id)
        } else {
            includedIDs.remove(playlist.id)
            stopUnchosen()
        }
    }

    /// Fetches every included playlist and queues anything not already on the phone.
    ///
    /// Safe to call often: it compares against the download catalog first, so a synced
    /// library makes this a handful of cheap requests and no transfers.
    func sync() async {
        guard isEnabled, !isSyncing,
              let client, let downloads
        else { return }

        if isWiFiOnly, reachability?.isExpensive == true {
            lastSummary = "Waiting for Wi-Fi"
            return
        }
        guard reachability?.isOnline != false else { return }

        isSyncing = true
        defer { isSyncing = false }

        guard let playlists = try? await client.playlists() else { return }

        var queued = 0
        for playlist in playlists where includedIDs.contains(playlist.id) {
            guard let detail = try? await client.playlistDetail(id: playlist.id) else { continue }

            let missing = detail.songs.filter { downloads.status(for: $0.id) == .none }
            guard !missing.isEmpty else { continue }

            // Grouped under the playlist so the Downloads screen shows why they are
            // here, and removing the group removes the lot.
            downloads.download(missing, groupID: playlist.id, groupName: playlist.name)
            queued += missing.count
        }

        if includesFavourites, let starred = try? await client.starred() {
            let missing = starred.songs.filter { downloads.status(for: $0.id) == .none }
            if !missing.isEmpty {
                // Their own group, so removing "Favourites" from Downloads does not
                // take a playlist's copies with it.
                downloads.download(missing, groupID: "favourites", groupName: "Favourites")
                queued += missing.count
            }
        }

        lastSummary = queued == 0
            ? "Everything is on this phone"
            : "Downloading \(queued) \(queued == 1 ? "track" : "tracks")"

        if queued > 0 {
            await Diagnostics.shared.record("playlist sync", "queued \(queued) tracks")
        }
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
