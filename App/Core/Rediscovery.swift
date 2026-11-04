import Foundation

/// The queries behind Rediscovery, shared by the Home shelf and the screen so they do not
/// each invent their own.
///
/// All of this exists because of one number: 95% of this library has never been played.
/// A client that only ever shows recently-added and most-played is a client that shows the
/// same 5% forever.
enum Rediscovery {
    struct Forgotten: Sendable {
        var songs: [Song] = []
        /// Keyed by song id. Absent means never played, which is not the same as unknown.
        var lastPlayed: [String: Date] = [:]

        /// `songs`, without what has been played in the last month, by either copy. The
        /// list is fetched once, and a favourite played since is not forgotten any more:
        /// the shelf kept offering the very songs being played from it (2026-11-03). It
        /// reads the history, so a screen showing it follows each play.
        @MainActor
        func remaining(after history: ListeningHistory, limit: Int = .max) -> [Song] {
            let since = Date.now.addingTimeInterval(-30 * 86_400)
            var played: Set<String> = []
            // Oldest first, so the month is at the end.
            for play in history.plays.reversed() {
                guard play.at >= since else { break }
                played.insert(MixEngine.identity(title: play.title, artist: play.artist))
            }
            return Array(songs.lazy.filter { !played.contains(MixEngine.identity($0)) }.prefix(limit))
        }
    }

    /// "8 months ago", or "Never" when the server has no play date at all.
    ///
    /// Main-actor because `RelativeDateTimeFormatter` is not `Sendable` and building one
    /// per row is measurably slow in a list.
    @MainActor
    static func lastPlayedText(_ date: Date?) -> String {
        guard let date else { return "Never" }
        return relativeFormatter.localizedString(for: date, relativeTo: .now)
    }

    @MainActor
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    /// Starred tracks, least recently played first.
    ///
    /// Two requests, deliberately. The native API knows the order — it is the only one
    /// that can sort by play date — but its rows are its own shape; `getStarred2` returns
    /// full songs the rest of the app can play, star and download. So the native call
    /// supplies the ordering and the dates, and Subsonic supplies the songs.
    @MainActor
    static func forgottenFavourites(
        appState: AppState,
        scope: LibraryScope,
        limit: Int = 50
    ) async -> Forgotten {
        async let ordering = try? appState.native.forgottenFavourites(limit: 200)
        async let starred = try? appState.client.starred(scope: scope)

        let songs = await starred?.songs ?? []
        guard !songs.isEmpty else { return Forgotten() }

        let order = await ordering ?? []
        var dates: [String: Date] = [:]
        for row in order {
            if let played = row.playDate { dates[row.id] = played }
        }

        let byID = Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [Song] = []
        var seen: Set<String> = []

        for row in order {
            guard let song = byID[row.id], seen.insert(song.id).inserted else { continue }
            result.append(song)
        }
        // Anything starred that the native call did not cover — a different folder scope,
        // or more than 200 favourites — still belongs on the list, just at the end.
        result += songs.filter { !seen.contains($0.id) }

        return Forgotten(songs: Array(result.prefix(limit)), lastPlayed: dates)
    }

    /// Songs from the never-played 95%.
    ///
    /// Random rather than paged: at that proportion one random page is a better sample
    /// than the first page of anything, and it gives a different answer each time, which
    /// is the whole point of the section.
    @MainActor
    static func neverPlayed(
        appState: AppState,
        scope: LibraryScope,
        limit: Int = 30
    ) async -> [Song] {
        let pool = (try? await appState.client.randomSongs(size: 200, scope: scope)) ?? []
        return Array(pool.filter { ($0.playCount ?? 0) == 0 }.prefix(limit))
    }

    /// Plays from around this date in a previous period — "a year ago today".
    ///
    /// The window is ±1 day, because a single date is often empty and the point is the
    /// memory, not the anniversary. Reads the app's own log, since the server keeps only
    /// the *last* play of each track.
    @MainActor
    static func plays(
        from history: ListeningHistory,
        daysAgo: Int,
        window: Int = 1,
        now: Date = .now
    ) -> [ListeningHistory.Play] {
        let calendar = Calendar.current
        guard let target = calendar.date(byAdding: .day, value: -daysAgo, to: now) else { return [] }

        let start = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -window, to: target) ?? target)
        let end = calendar.date(byAdding: .day, value: window + 1, to: calendar.startOfDay(for: target)) ?? target

        var seen: Set<String> = []
        return history.plays
            .filter { $0.at >= start && $0.at < end }
            .filter { seen.insert($0.songID).inserted }
            .sorted { $0.at > $1.at }
    }

    /// Turns logged plays back into playable songs.
    ///
    /// `getSong.view`, one request each, which is why the caller passes a handful rather
    /// than a day's listening. A track that has since been deleted from the library simply
    /// drops out — better than a row that does nothing when tapped.
    @MainActor
    static func resolve(
        _ plays: [ListeningHistory.Play],
        appState: AppState,
        limit: Int = 12
    ) async -> [Song] {
        var songs: [Song] = []
        for play in plays.prefix(limit) {
            if let song = try? await appState.client.song(id: play.songID) {
                songs.append(song)
            }
        }
        return songs
    }
}
