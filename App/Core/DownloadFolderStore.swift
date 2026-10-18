import Foundation
import Observation

/// The Downloads tab's folders, rebuilt when the download catalog changes and at no other
/// time.
///
/// Its own object rather than a computed property on a view, for the lag: grouping a few
/// thousand songs inside `body` ran on every redraw, and while an album downloads the
/// catalog changes with every track. Here a burst of finished tracks is one rebuild, the
/// rebuild runs off the main thread, and no view has to read `DownloadCenter.progress` —
/// folder progress is whole tracks, which the catalog already has.
@MainActor
@Observable
final class DownloadFolderStore {
    private(set) var folders = DownloadFolders()

    @ObservationIgnored private weak var downloads: DownloadCenter?
    @ObservationIgnored private var cache: LibraryCache?
    @ObservationIgnored private var isActive = false
    @ObservationIgnored private var scheduled: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    /// Song ids in playlist order, from cached copies of the playlists.
    @ObservationIgnored private var playlistOrders: [String: [String]] = [:]
    @ObservationIgnored private var lookedUp: Set<String> = []

    func configure(downloads: DownloadCenter, cache: LibraryCache) {
        self.downloads = downloads
        self.cache = cache
    }

    /// Starts following the catalog. Lazy, so a phone that never opens Downloads never
    /// pays for it; the first build is synchronous so the tab never flashes empty.
    func activate() {
        guard !isActive, let downloads else { return }
        isActive = true
        folders = DownloadFolders(catalog: downloads.catalog, playlistOrders: playlistOrders)
        observe()
        loadPlaylistOrders()
    }

    /// A fresher order for one playlist, fetched by the folder screen while online.
    func update(order songIDs: [String], forPlaylist key: String) {
        guard playlistOrders[key] != songIDs else { return }
        playlistOrders[key] = songIDs
        scheduleRebuild()
    }

    // MARK: - Following the catalog

    private func observe() {
        guard let downloads else { return }
        withObservationTracking {
            _ = downloads.catalog
        } onChange: { [weak self] in
            // Called before the new value is stored, and only once; the task runs after
            // the change lands and signs up for the next one.
            Task { @MainActor in
                self?.observe()
                self?.scheduleRebuild()
            }
        }
    }

    private func scheduleRebuild() {
        guard scheduled == nil else { return }
        scheduled = Task { [weak self] in
            // Tracks finish in bursts; this makes a burst one rebuild.
            try? await Task.sleep(for: .milliseconds(150))
            await self?.rebuild()
        }
    }

    private func rebuild() async {
        scheduled = nil
        guard let downloads else { return }
        generation += 1
        let current = generation
        let catalog = downloads.catalog
        let orders = playlistOrders

        let built = await Task.detached(priority: .userInitiated) {
            DownloadFolders(catalog: catalog, playlistOrders: orders)
        }.value

        // A later rebuild may have started, and finished, while this one ran.
        guard current == generation else { return }
        folders = built
        loadPlaylistOrders()
    }

    /// Reads the cached copy of each playlist the first time it shows up, for its order.
    /// From disk only: this has to work with the server off, and a request to a server
    /// that is down would only stall it.
    private func loadPlaylistOrders() {
        guard let cache else { return }
        let wanted = folders.playlists.map(\.key).filter { !lookedUp.contains($0) }
        guard !wanted.isEmpty else { return }
        lookedUp.formUnion(wanted)

        Task { [weak self] in
            var found: [String: [String]] = [:]
            for key in wanted {
                if let detail = await cache.load(PlaylistDetail.self, for: CacheKey.playlist(key)) {
                    found[key] = detail.songs.map(\.id)
                }
            }
            guard let self, !found.isEmpty else { return }
            playlistOrders.merge(found) { _, new in new }
            scheduleRebuild()
        }
    }
}
