import Foundation
import Observation

/// Every album in the library, in memory: what Plexamp's library categories and several
/// of its home hubs are cut from.
///
/// Navidrome can list albums by name, year, genre and play count, but not by record label,
/// mood or release type, and it cannot say which albums came out on this day. Those need
/// the whole list. A library of a few thousand albums is a few requests of 500 and a
/// couple of megabytes, so it is fetched whole, kept on disk for the next launch and for
/// offline, and refreshed at most every few hours.
@MainActor
@Observable
final class LibraryIndex {
    private(set) var albums: [Album] = []
    private(set) var isLoading = false

    @ObservationIgnored private var loadedScope: String?
    @ObservationIgnored private var loadedAt: Date?
    @ObservationIgnored private weak var appState: AppState?

    /// Long enough that browsing never waits, short enough that a new album shows up the
    /// same evening.
    private let freshFor: TimeInterval = 6 * 3_600
    private let pageSize = 500

    func configure(appState: AppState) {
        self.appState = appState
    }

    /// Loads the index for a scope if it is not already fresh. Cheap to call from every
    /// screen that needs it.
    func ensureLoaded(scope: LibraryScope) async {
        guard let appState, !isLoading else { return }
        let key = CacheKey.albumList("all", scope.cacheKey)
        if loadedScope == key, let loadedAt, Date.now.timeIntervalSince(loadedAt) < freshFor { return }

        isLoading = true
        defer { isLoading = false }

        // Last launch's copy first, so the screen is never empty while the fresh one loads.
        if loadedScope != key, let stored = await appState.cache.load([Album].self, for: key) {
            albums = stored
            loadedScope = key
        }

        var fetched: [Album] = []
        var offset = 0
        while true {
            guard let page = try? await appState.client.albums(
                type: .alphabeticalByName, size: pageSize, offset: offset, scope: scope
            ) else {
                // Offline or failing: keep whatever there is, and try again next time.
                return
            }
            fetched += page
            guard page.count == pageSize else { break }
            offset += pageSize
        }

        albums = fetched
        loadedScope = key
        loadedAt = .now
        await appState.cache.store(fetched, for: key)

        // Every album's cover to disk, at the sizes grids and rows draw, so no cover is
        // ever first seen from the network. Wi-Fi only: a few thousand covers is a couple
        // of hundred megabytes. Only the missing ones are fetched, so later runs are file
        // checks.
        if appState.reachability.network == .wifi {
            appState.artwork.warm(fetched.compactMap(\.coverArt), sizes: [.thumb, .card])
        }
    }

    var compilations: [Album] { LibraryFacets.ofKind(.compilation, in: albums) }
    var soundtracks: [Album] { LibraryFacets.ofKind(.soundtrack, in: albums) }
    var live: [Album] { LibraryFacets.ofKind(.live, in: albums) }
    var singles: [Album] { LibraryFacets.ofKind(.singleOrEP, in: albums) }
    var labels: [LibraryFacets.Group] { LibraryFacets.labels(albums) }
    var moods: [LibraryFacets.Group] { LibraryFacets.moods(albums) }
}
