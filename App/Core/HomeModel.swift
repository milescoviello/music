import Foundation
import Observation

/// Home's shelves, loaded together: the server's album lists, favourites, the forgotten
/// favourites, this month's chart from the local history, a genre to explore, and the
/// shelves cut from the whole album list. Moved here from `HomeView` so the Linux build's
/// Home is the same model.
@MainActor
@Observable
final class HomeModel {
    var recentlyPlayed: [Album] = []
    var recentlyAdded: [Album] = []
    var mostPlayed: [Album] = []
    var favoriteSongs: [Song] = []
    var forgotten = Rediscovery.Forgotten()
    var onThisDay: [(album: Album, years: Int)] = []
    var bestOfLastYear: [Album] = []
    var notPlayedLately: [Album] = []
    var moreInGenre: (name: String, albums: [Album])?
    var mostPlayedThisMonth: [Album] = []
    var hasLoaded = false

    /// Plexamp's "Most Played in October": whichever month the chart opens on.
    var monthTitle: String {
        let period = ChartPeriod.current(.month)
        return "Most Played in \(period.start.formatted(.dateTime.month(.wide)))"
    }

    var lastYear: Int { Calendar.current.component(.year, from: .now) - 1 }

    var isEmpty: Bool {
        recentlyPlayed.isEmpty && recentlyAdded.isEmpty
            && mostPlayed.isEmpty && favoriteSongs.isEmpty && forgotten.songs.isEmpty
            && onThisDay.isEmpty && bestOfLastYear.isEmpty && notPlayedLately.isEmpty
            && mostPlayedThisMonth.isEmpty
    }

    /// Shelves load concurrently and a failing shelf is simply dropped: one dead
    /// endpoint should not replace the whole screen with an error.
    ///
    /// Each goes through `appState.cached`, so Home is the same screen offline as on --
    /// which it was not before: every shelf simply came back empty, and an empty Home
    /// reads as a broken app rather than an offline one.
    func load(appState: AppState, scope: LibraryScope) async {
        appState.beginLoadPass()

        let client = appState.client
        let key = scope.cacheKey

        async let played: [Album]? = appState.cached(CacheKey.shelf("recent", key)) {
            try await client.albums(type: .recent, size: 12, scope: scope)
        }
        async let added: [Album]? = appState.cached(CacheKey.shelf("newest", key)) {
            try await client.albums(type: .newest, size: 12, scope: scope)
        }
        async let frequent: [Album]? = appState.cached(CacheKey.shelf("frequent", key)) {
            try await client.albums(type: .frequent, size: 12, scope: scope)
        }
        async let starred: Starred2? = appState.cached(CacheKey.starred(key)) {
            try await client.starred(scope: scope)
        }
        // Not cached: it is derived from two calls, and offline the starred list it is
        // built from is already served from the cache above.
        async let neglected = Rediscovery.forgottenFavourites(appState: appState, scope: scope, limit: 3)

        recentlyPlayed = await played ?? []
        recentlyAdded = await added ?? []
        mostPlayed = await frequent ?? []
        favoriteSongs = Array((await starred?.songs ?? []).prefix(4))
        forgotten = await neglected
        hasLoaded = true

        // From this phone's own history: the server counts plays but never dates them.
        // Worked out off the main actor: it is the whole log, up to 20,000 plays, at the
        // moment Home is first drawn and being scrolled. Which, at launch, may be before
        // the log has been read.
        await appState.history.loaded()
        let history = appState.history.plays
        let month = ChartPeriod.current(.month)
        let monthRows = await Task.detached(priority: .userInitiated) {
            Charts.topAlbums(history.map { $0.chartPlay }, in: month, limit: 12)
        }.value
        mostPlayedThisMonth = monthRows.compactMap { row in
            guard let id = row.albumID else { return nil }
            var album = Album(id: id, name: row.title)
            album.artist = row.subtitle
            album.coverArt = row.coverArt
            return album
        }

        // The shelves cut from the whole album list. After the rest, so they never hold
        // Home up; the list itself is kept on disk and only refetched every few hours.
        if let genre = recentlyPlayed.lazy.compactMap(\.genre).first(where: { !$0.isEmpty }) {
            let seen = Set(recentlyPlayed.map(\.id))
            let albums = (try? await client.albums(type: .random, size: 20, scope: scope, genre: genre)) ?? []
            let fresh = albums.filter { !seen.contains($0.id) }
            moreInGenre = fresh.isEmpty ? nil : (genre, fresh)
        }

        let index = appState.libraryIndex
        await index.ensureLoaded(scope: scope)
        // The same, for a few thousand albums run through the calendar.
        let albums = index.albums
        let year = lastYear
        let sixMonthsAgo = Calendar.current.date(byAdding: .month, value: -6, to: .now) ?? .now
        let facets = await Task.detached(priority: .userInitiated) {
            (
                onThisDay: LibraryFacets.onThisDay(albums, on: .now),
                bestOf: LibraryFacets.bestOf(year: year, in: albums),
                notPlayed: LibraryFacets.notPlayedSince(sixMonthsAgo, in: albums)
            )
        }.value
        onThisDay = facets.onThisDay
        bestOfLastYear = facets.bestOf
        notPlayedLately = facets.notPlayed
    }
}
