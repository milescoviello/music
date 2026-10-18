import Foundation
import Observation

/// Mixes, as many as you keep asking for, stable for the day.
///
/// The reason this can exist at all is that the app keeps its own play log: the server
/// knows *how many* times a track was played but not *when*, so "what you have been into
/// lately" is not a question Subsonic can answer. `MixEngine` does the choosing; this
/// fetches the candidates and remembers the result.
///
/// Built in **pages**, from a list of recipes rather than a fixed set of three. Reaching
/// the end of the shelf asks for more, and so does listening — the ideas do not run out
/// before the cap does: a dozen favourite artists, sixteen genres each with a played and
/// an unheard version, seven decades. Nothing is ever built twice, because a page picks up
/// where the last one left off and shares one `used` set with it.
///
/// Stable for the day, though: a mix that changes while you are looking at it is not a
/// mix. Pages already built are cached, so scrolling back is free and a relaunch resumes
/// mid-list.
@MainActor
@Observable
final class DailyMixes {
    struct Mix: Codable, Sendable, Identifiable {
        let id: String
        var title: String
        var subtitle: String
        var songs: [Song]
        /// Which recipe produced this, so scrolling to the bottom can ask it for more.
        /// Optional: mixes cached before extending existed have none and fall back to
        /// radio, which works for any mix.
        var recipeIndex: Int?
        /// Set once a mix has stopped producing anything new, so a list can stop asking.
        var isExhausted: Bool?

        /// Up to four covers, for the tiled card. Distinct albums, so a mix that happens
        /// to open with three tracks off one record still looks like a mix.
        var covers: [String] {
            var seen: [String] = []
            for art in songs.compactMap(\.coverArt) where !seen.contains(art) {
                seen.append(art)
                if seen.count == 4 { break }
            }
            return seen
        }
    }

    /// Below this a "mix" is a short playlist. Twelve rather than fifteen because the
    /// original figure was silently dropping mixes that were perfectly usable: eight
    /// favourite artists at three tracks each is 24 candidates *before* de-duplication and
    /// the excluded week, and this library's twin copies eat a lot of that.
    static let minimumTracks = 12

    /// Where "endless" stops. Forty shelves is more than anyone scrolls in a day, and it
    /// keeps the cached file and the recipe list to a size that is honest about the
    /// library underneath: past this point the pools are thin enough that a mix stops
    /// being a recommendation.
    static let maximumMixes = 40

    /// Tracks added each time a mix is extended. Fifty rather than twenty-five: the wait
    /// is dominated by the round trips, not the size of the answer, so a bigger batch
    /// means far fewer waits for the same work.
    private static let extensionSize = 50

    /// How many the first page builds. Enough for the shelf to look deliberate before
    /// anyone scrolls.
    private static let firstPageSize = 4
    /// And how many each request after that adds.
    private static let pageSize = 2

    /// While listening, the shelf grows on its own up to here; beyond it, only scrolling
    /// asks for more. Music playing is a good signal that mixes are wanted; it is not a
    /// reason to build forty of them.
    private static let whileListeningTarget = 10

    private(set) var mixes: [Mix] = []
    private(set) var isBuilding = false
    /// False once the recipes are exhausted or the cap is reached, so a list can stop
    /// showing a spinner that will never resolve.
    private(set) var canLoadMore = true

    private var builtDay: Date?
    private var builtScope: String?
    private var buildTask: Task<Void, Never>?
    private var extendTask: Task<Void, Never>?
    /// Separate from `isBuilding`: a mix growing at the bottom of its own screen is a
    /// different thing to say than "the shelf is being built".
    private(set) var isExtending = false

    /// Called with the tracks an extension added. The player uses it to keep a queue that
    /// is playing this mix from ever reaching the end.
    var onExtended: ((Mix, [Song]) -> Void)?

    /// Everything a page needs that is worth fetching only once a day.
    private struct Context {
        var samples: [MixEngine.Sample]
        var artists: [String]
        var genres: [String]
        var recent: Set<String>
        /// Kept from Heavy Rotation: these carry the genre tags and cost eight requests.
        var artistCandidates: [Song]
    }

    private var context: Context?
    private var used: Set<String> = []
    private var identities: Set<String> = []
    /// The next recipe to try. Persisted, so a relaunch resumes rather than repeating.
    private var nextRecipe = 0

    private struct Stored: Codable, Sendable {
        var day: Date
        var scope: String
        var mixes: [Mix]
        /// Optional, per this batch's rule: files written before paging existed decode as
        /// nil and simply start their recipes from the beginning.
        var nextRecipe: Int?
    }

    func mix(id: String) -> Mix? { mixes.first { $0.id == id } }

    /// Throws away today's answer so the next `load` rebuilds from the first recipe.
    /// Used by the Diagnostics screen, since "why is this shelf empty" is otherwise
    /// unanswerable from the phone.
    func forgetToday() {
        buildTask?.cancel()
        buildTask = nil
        builtDay = nil
        builtScope = nil
        context = nil
        used = []
        identities = []
        nextRecipe = 0
        canLoadMore = true
        mixes = []
    }

    /// The first page, or nothing if today's is already in hand.
    ///
    /// **Not** `async`, and the work runs in a task this object owns. It used to be awaited
    /// straight from Home's `.task`, which SwiftUI cancels the moment that view goes away —
    /// so opening a mix, or switching tabs, killed the build part-way through. The first
    /// stage had already finished, so what got cached for the day was Heavy Rotation and
    /// nothing else. An unstructured `Task` does not inherit that cancellation.
    ///
    /// Yesterday's are shown while today's are being built, and kept if the build fails —
    /// offline, stale mixes are worth far more than an empty shelf, and every track in them
    /// is playable if it was downloaded.
    func load(appState: AppState, scope: LibraryScope) {
        start(appState: appState, scope: scope, wanted: Self.firstPageSize)
    }

    /// Another page. Called when the shelf is scrolled to its end, or the bottom of Home
    /// is reached — which is what makes this endless rather than a fixed set.
    func loadMore(appState: AppState, scope: LibraryScope) {
        guard canLoadMore else { return }
        start(appState: appState, scope: scope, wanted: Self.pageSize)
    }

    /// Grows the shelf while music is playing, up to a point.
    ///
    /// Listening is a good signal that mixes are wanted, and it costs nothing to have the
    /// next couple ready before anyone scrolls to them. It is not a reason to build forty.
    func topUpWhileListening(appState: AppState, scope: LibraryScope) {
        guard canLoadMore, mixes.count < Self.whileListeningTarget else { return }
        start(appState: appState, scope: scope, wanted: Self.pageSize)
    }

    /// Waits for whatever build is in flight. For the Diagnostics button, which wants to
    /// show the outcome rather than start it and walk away.
    func loadAndWait(appState: AppState, scope: LibraryScope) async {
        load(appState: appState, scope: scope)
        await buildTask?.value
    }

    private func start(appState: AppState, scope: LibraryScope, wanted: Int) {
        let today = Calendar.current.startOfDay(for: .now)

        // A new day, or a different folder scope, means starting over.
        if builtDay != nil, builtDay != today || builtScope != scope.cacheKey {
            forgetToday()
        }
        guard buildTask == nil, mixes.count < Self.maximumMixes else { return }

        buildTask = Task { [weak self] in
            await self?.page(appState: appState, scope: scope, day: today, wanted: wanted)
            self?.buildTask = nil
        }
    }

    // MARK: - Paging

    private func page(appState: AppState, scope: LibraryScope, day: Date, wanted: Int) async {
        let scopeKey = scope.cacheKey
        let key = "daily-mixes-\(scopeKey)"

        // First call of the session: adopt whatever was built earlier today, including how
        // far down the recipe list it got, so scrolling back is free and paging resumes.
        if mixes.isEmpty, builtDay == nil,
           let stored: Stored = await appState.cache.load(Stored.self, for: key),
           stored.day == day, stored.scope == scopeKey {
            mixes = stored.mixes
            nextRecipe = stored.nextRecipe ?? stored.mixes.count
            builtDay = stored.day
            builtScope = stored.scope
            for mix in stored.mixes { record(mix.songs) }
            if mixes.count >= wanted { return }
        }

        guard !isBuilding else { return }
        isBuilding = true
        defer { isBuilding = false }

        guard let context = await ensureContext(appState: appState) else { return }

        var added = 0
        var attempts = 0

        // Recipes are tried until the page is filled. A recipe that cannot fill a mix is
        // skipped rather than retried -- a genre with nine tracks in it will still have
        // nine tomorrow -- and enough consecutive failures mean the ideas have run out.
        while added < wanted, attempts < 10, mixes.count < Self.maximumMixes {
            let index = nextRecipe
            nextRecipe += 1
            attempts += 1

            guard let mix = await build(
                Self.recipe(at: index),
                index: index,
                appState: appState,
                context: context,
                scope: scope,
                day: day
            ) else { continue }

            var built = mix
            built.recipeIndex = index
            record(built.songs)
            mixes.append(built)
            added += 1
            attempts = 0
        }

        if added == 0, attempts >= 10 {
            canLoadMore = false
            await Diagnostics.shared.record("mixes", "no more recipes could be filled")
        }
        if mixes.count >= Self.maximumMixes { canLoadMore = false }

        guard !mixes.isEmpty else {
            // Logged because the failure is invisible otherwise: an empty shelf simply
            // does not render, which looks identical to the feature not existing.
            await Diagnostics.shared.record("mixes", "built nothing — see the stage lines above")
            return
        }

        builtDay = day
        builtScope = scopeKey
        await appState.cache.store(
            Stored(day: day, scope: scopeKey, mixes: mixes, nextRecipe: nextRecipe), for: key
        )
    }

    /// Adds another batch of tracks to a mix that is already on screen.
    ///
    /// This is what makes a mix worth sitting in: Heavy Rotation is not a 25-track list,
    /// it is a station. The recipe that produced it is asked for more first — it excludes
    /// everything already used, so a second run genuinely returns different tracks — and
    /// when the recipe's own pool runs dry it continues as radio, seeded from the tracks
    /// already in the mix. That part cannot run out.
    func extend(mixID: String, appState: AppState, scope: LibraryScope) {
        guard let position = mixes.firstIndex(where: { $0.id == mixID }),
              mixes[position].isExhausted != true,
              extendTask == nil
        else { return }

        extendTask = Task { [weak self] in
            await self?.runExtension(at: position, appState: appState, scope: scope)
            self?.extendTask = nil
        }
    }

    private func runExtension(at position: Int, appState: AppState, scope: LibraryScope) async {
        guard mixes.indices.contains(position) else { return }
        let mix = mixes[position]
        let before = mix.songs.count
        isExtending = true
        defer { isExtending = false }

        // The generator keys on the *day*, so extending within the same day would shuffle
        // identically. Nudging the seed forward one notional day per batch gives each
        // extension its own order while keeping the whole thing reproducible.
        let seedDay = Calendar.current.date(
            byAdding: .day, value: before / Self.extensionSize, to: builtDay ?? .now
        ) ?? .now
        let seed = mix.songs.suffix(8).randomElement()

        // Both sources are started **together**, not one after the other. Sequentially
        // this waited for the recipe -- up to nine requests for a decade mix -- decided it
        // was short, and only then went to the radio for another two. Concurrently the
        // whole extension costs the slower of the two rather than their sum.
        async let fromRecipe = recipeExtension(
            mix: mix, appState: appState, scope: scope, day: seedDay
        )
        async let fromRadio = radioExtension(seed: seed, appState: appState, scope: scope)

        var addition = await fromRecipe
        let radio = await fromRadio

        if addition.count < Self.extensionSize, !radio.isEmpty {
            var generator = MixEngine.DayRandom(day: seedDay, salt: UInt64(before))
            addition += MixEngine.choose(
                from: radio.filter { $0.id != seed?.id },
                limit: Self.extensionSize - addition.count,
                perArtist: 3,
                excluding: used.union(addition.map(\.id)),
                usedIdentities: identities.union(addition.map(MixEngine.identity)),
                using: &generator
            )
        }

        guard !addition.isEmpty else {
            mixes[position].isExhausted = true
            await Diagnostics.shared.record("mixes", "“\(mix.title)” had nothing more to add")
            return
        }

        record(addition)
        mixes[position].songs += addition
        onExtended?(mixes[position], addition)
        await Diagnostics.shared.record(
            "mixes", "“\(mix.title)” grew from \(before) to \(mixes[position].songs.count)"
        )
        await persist(appState: appState, scope: scope)
    }

    private func recipeExtension(
        mix: Mix,
        appState: AppState,
        scope: LibraryScope,
        day: Date
    ) async -> [Song] {
        guard let index = mix.recipeIndex, let context else { return [] }
        let built = await build(
            Self.recipe(at: index), index: index, appState: appState,
            context: context, scope: scope, day: day
        )
        return built?.songs ?? []
    }

    private func radioExtension(
        seed: Song?,
        appState: AppState,
        scope: LibraryScope
    ) async -> [Song] {
        guard let seed else { return [] }
        return await appState.radio.mix(seed: seed, scope: scope, size: 80)
    }

    private func persist(appState: AppState, scope: LibraryScope) async {
        guard let day = builtDay else { return }
        await appState.cache.store(
            Stored(day: day, scope: scope.cacheKey, mixes: mixes, nextRecipe: nextRecipe),
            for: "daily-mixes-\(scope.cacheKey)"
        )
    }

    /// What to build, in order. The first six are the ones worth having every day; after
    /// that it cycles through artists, genres, decades and the unplayed corners of each,
    /// which is what keeps this from running dry before the cap does.
    private enum Recipe {
        case heavy
        case deepCuts
        case newToYou
        case fresh
        case genre(Int)
        case artistRadio(Int)
        case decade(Int)
        case unheardGenre(Int)
    }

    private static func recipe(at index: Int) -> Recipe {
        switch index {
        case 0: return .heavy
        case 1: return .genre(0)
        case 2: return .deepCuts
        case 3: return .newToYou
        case 4: return .genre(1)
        case 5: return .fresh
        default:
            let step = index - 6
            let round = step / 4
            switch step % 4 {
            case 0: return .artistRadio(round)
            case 1: return .genre(2 + round)
            case 2: return .decade(round)
            default: return .unheardGenre(round)
            }
        }
    }

    private func build(
        _ recipe: Recipe,
        index: Int,
        appState: AppState,
        context: Context,
        scope: LibraryScope,
        day: Date
    ) async -> Mix? {
        switch recipe {
        case .heavy:
            return await heavyRotation(
                appState: appState, artists: context.artists, recent: context.recent,
                candidates: context.artistCandidates, day: day,
                used: used, identities: identities
            )

        case .deepCuts:
            return await deepCuts(
                appState: appState, artists: context.artists, scope: scope, day: day,
                used: used, identities: identities
            )

        case .newToYou:
            return await newToYou(
                appState: appState, samples: context.samples, scope: scope, day: day,
                used: used, identities: identities
            )

        case .fresh:
            return await freshAdditions(
                appState: appState, scope: scope, day: day,
                used: used, identities: identities
            )

        case let .genre(position):
            guard context.genres.indices.contains(position) else { return nil }
            return await genreMix(
                appState: appState, genre: context.genres[position], index: index,
                unplayedOnly: false, scope: scope, day: day,
                used: used, identities: identities
            )

        case let .unheardGenre(position):
            guard context.genres.indices.contains(position) else { return nil }
            return await genreMix(
                appState: appState, genre: context.genres[position], index: index,
                unplayedOnly: true, scope: scope, day: day,
                used: used, identities: identities
            )

        case let .artistRadio(position):
            guard context.artists.indices.contains(position) else { return nil }
            return await artistRadio(
                appState: appState, artist: context.artists[position], index: index,
                scope: scope, day: day, used: used, identities: identities
            )

        case let .decade(position):
            let decades = [2020, 2010, 2000, 1990, 1980, 1970, 1960]
            guard decades.indices.contains(position) else { return nil }
            return await decadeMix(
                appState: appState, decade: decades[position], index: index,
                scope: scope, day: day, used: used, identities: identities
            )
        }
    }

    /// The expensive, once-a-day part: the play log, the artist ranking, and the eight
    /// `getTopSongs` calls whose results the genre ranking also needs.
    private func ensureContext(appState: AppState) async -> Context? {
        if let context { return context }

        let samples = await samples(appState: appState)
        guard !samples.isEmpty else {
            await Diagnostics.shared.record(
                "mixes", "no history and no server play counts — nothing to build from"
            )
            return nil
        }
        await Diagnostics.shared.record(
            "mixes",
            "\(samples.count) samples (\(appState.history.plays.count) local plays)"
        )

        // Off the main actor: every sample through the calendar, up to 20,000 of them, and
        // this runs as Home first appears after launch.
        let (artists, recent) = await Task.detached(priority: .userInitiated) {
            (
                MixEngine.ranked(MixEngine.artistScores(samples), limit: 16),
                MixEngine.songIDs(samples, playedWithin: 7)
            )
        }.value
        let candidates = await artistCandidates(appState: appState, artists: Array(artists.prefix(8)))
        let genres = await topGenres(
            appState: appState, samples: samples, candidates: candidates,
            scope: appState.scope.scope, limit: 16
        )

        let built = Context(
            samples: samples,
            artists: artists,
            genres: genres,
            recent: recent,
            artistCandidates: candidates
        )
        context = built
        return built
    }

    /// Tracks by favourite artists that have never once been played.
    ///
    /// Different from New to You, which reaches for anything unplayed: this stays with
    /// artists already loved and finds the album tracks behind the songs. `getTopSongs`
    /// cannot answer it — by definition it returns the *played* ones — so this searches by
    /// artist name and filters on the play count.
    private func deepCuts(
        appState: AppState,
        artists: [String],
        scope: LibraryScope,
        day: Date,
        used: Set<String>,
        identities: Set<String>
    ) async -> Mix? {
        var pool: [Song] = []
        await withTaskGroup(of: [Song].self) { group in
            for artist in artists.prefix(4) {
                group.addTask { [client = appState.client] in
                    let found = try? await client.search(
                        query: artist, artistCount: 0, albumCount: 0, songCount: 60, scope: scope
                    )
                    return (found?.songs ?? []).filter {
                        ($0.playCount ?? 0) == 0
                            && $0.artist?.localizedCaseInsensitiveContains(artist) == true
                    }
                }
            }
            for await songs in group { pool += songs }
        }
        guard !pool.isEmpty else { return nil }

        var generator = MixEngine.DayRandom(day: day, salt: 4)
        let chosen = MixEngine.choose(
            from: pool, limit: 25, perArtist: 4,
            excluding: used, usedIdentities: identities, using: &generator
        )
        await Diagnostics.shared.record(
            "mixes", "deep cuts: \(pool.count) candidates, \(chosen.count) chosen"
        )
        guard chosen.count >= Self.minimumTracks else { return nil }

        return Mix(
            id: "deep",
            title: "Deep Cuts",
            subtitle: "Unplayed, by artists you know",
            songs: chosen
        )
    }

    /// One artist's own orbit: their tracks plus what the server thinks sits next to them.
    ///
    /// `getSimilarSongs2` needs a *song* id — an artist id returns nothing on this server —
    /// so the seed is that artist's best-known track.
    private func artistRadio(
        appState: AppState,
        artist: String,
        index: Int,
        scope: LibraryScope,
        day: Date,
        used: Set<String>,
        identities: Set<String>
    ) async -> Mix? {
        let top = (try? await appState.client.topSongs(artist: artist, count: 4)) ?? []
        guard let seed = top.first else { return nil }

        var pool = top
        pool += (try? await appState.client.similarSongs(toSongID: seed.id, count: 60)) ?? []
        guard pool.count > 4 else { return nil }

        var generator = MixEngine.DayRandom(day: day, salt: UInt64(400 + index))
        let chosen = MixEngine.choose(
            from: pool, limit: 25, perArtist: 3,
            excluding: used, usedIdentities: identities, using: &generator
        )
        await Diagnostics.shared.record(
            "mixes", "radio “\(artist)”: \(pool.count) candidates, \(chosen.count) chosen"
        )
        guard chosen.count >= Self.minimumTracks else { return nil }

        return Mix(
            id: "radio-\(index)",
            title: "\(artist) Radio",
            subtitle: "And artists like them",
            songs: chosen
        )
    }

    /// A decade of the library.
    ///
    /// Albums first, then their tracks: there is no song-level year filter in Subsonic, and
    /// the album route is the one that exists. Note the server filters on the *release*
    /// year while rows print the *original* year, so a reissue can look out of place — that
    /// is the server's answer, not a mistake to correct locally.
    private func decadeMix(
        appState: AppState,
        decade: Int,
        index: Int,
        scope: LibraryScope,
        day: Date,
        used: Set<String>,
        identities: Set<String>
    ) async -> Mix? {
        let albums = (try? await appState.client.albums(
            fromYear: decade, toYear: decade + 9, size: 40, scope: scope
        )) ?? []
        guard !albums.isEmpty else { return nil }

        var generator = MixEngine.DayRandom(day: day, salt: UInt64(600 + index))
        var pool: [Song] = []
        let chosenAlbums = albums.shuffled(using: &generator).prefix(8)
        await withTaskGroup(of: [Song].self) { group in
            for album in chosenAlbums {
                group.addTask { [client = appState.client] in
                    (try? await client.albumDetail(id: album.id))?.songs ?? []
                }
            }
            for await songs in group {
                pool += songs
            }
        }
        guard !pool.isEmpty else { return nil }

        let chosen = MixEngine.choose(
            from: pool, limit: 25, perArtist: 2,
            excluding: used, usedIdentities: identities, using: &generator
        )
        await Diagnostics.shared.record(
            "mixes", "decade \(decade)s: \(albums.count) albums, \(chosen.count) chosen"
        )
        guard chosen.count >= Self.minimumTracks else { return nil }

        return Mix(
            id: "decade-\(index)",
            title: "\(decade)s Mix",
            subtitle: "From your \(decade)s records",
            songs: chosen
        )
    }

    /// Newly added music that has not been touched yet.
    ///
    /// Whole albums are the unit here because new arrivals are usually albums — often ones
    /// Hermes just fetched — and hearing one in order is the point.
    private func freshAdditions(
        appState: AppState,
        scope: LibraryScope,
        day: Date,
        used: Set<String>,
        identities: Set<String>
    ) async -> Mix? {
        let albums = (try? await appState.client.albums(type: .newest, size: 10, scope: scope)) ?? []
        // Concurrently: six sequential album fetches was most of the wait on this recipe,
        // and they do not depend on each other.
        var pool: [Song] = []
        await withTaskGroup(of: [Song].self) { group in
            for album in albums.prefix(6) {
                group.addTask { [client = appState.client] in
                    (try? await client.albumDetail(id: album.id))?.songs ?? []
                }
            }
            for await songs in group {
                pool += songs.filter { ($0.playCount ?? 0) == 0 }
            }
        }
        guard !pool.isEmpty else { return nil }

        var generator = MixEngine.DayRandom(day: day, salt: 5)
        let chosen = MixEngine.choose(
            from: pool, limit: 25, perArtist: 6,
            excluding: used, usedIdentities: identities, using: &generator
        )
        await Diagnostics.shared.record(
            "mixes", "fresh: \(albums.count) new albums, \(pool.count) unplayed, \(chosen.count) chosen"
        )
        guard chosen.count >= Self.minimumTracks else { return nil }

        return Mix(
            id: "fresh",
            title: "Fresh Additions",
            subtitle: "Recently added, not yet played",
            songs: chosen
        )
    }

    /// The play log, or the server's counts when the log is too thin to mean anything.
    ///
    /// Cold start is where the Plex import earns its keep: 1,322 tracks already carry a
    /// play count, so day one is personal instead of random. Server rows have no genre —
    /// only the app's own log does — which is why the genre mix has its own fallback.
    private func samples(appState: AppState) async -> [MixEngine.Sample] {
        // The mixes are built once a day and kept, so they must not be built from a log
        // that, just after launch, has not been read yet.
        await appState.history.loaded()
        let plays = appState.history.plays
        var samples = await Task.detached(priority: .userInitiated) {
            plays.map { MixEngine.Sample(songID: $0.songID, artist: $0.artist, genre: $0.genre, at: $0.at) }
        }.value

        guard samples.count < 40 else { return samples }

        let counted = (try? await appState.native.mostPlayed(limit: 200)) ?? []
        samples += counted.compactMap { song in
            guard let artist = song.artist, let count = song.playCount, count > 0 else { return nil }
            return MixEngine.Sample(
                songID: song.id,
                artist: artist,
                genre: nil,
                // No play *events* to place, so the last play stands in for all of them.
                at: song.playDate ?? .now,
                weight: Double(count)
            )
        }
        return samples
    }

    /// Favourite artists, minus this week's listening. Returns the candidates too, since
    /// they carry the genre tags the next mix needs and were expensive to fetch.
    /// The top artists' best-known tracks. Fetched once per day and kept, because the
    /// genre ranking reads their tags and every later page would otherwise re-fetch them.
    private func artistCandidates(appState: AppState, artists: [String]) async -> [Song] {
        var candidates: [Song] = []
        // Eight artists at once rather than in turn: this is the first thing that happens
        // on a cold Home, so it is the wait people actually see.
        await withTaskGroup(of: [Song].self) { group in
            for artist in artists {
                group.addTask { [client = appState.client] in
                    var songs = (try? await client.topSongs(artist: artist, count: 8)) ?? []
                    // `getTopSongs` is Last.fm's global chart, and Navidrome matches it to
                    // local files by title — badly. Nirvana has 67 tracks here and one
                    // matched. A thin answer means poor matching, not an unknown artist.
                    if songs.count < 3 {
                        let extra = try? await client.search(query: artist, songCount: 12)
                        songs += (extra?.songs ?? []).filter { $0.artist == artist }
                    }
                    return songs
                }
            }
            for await songs in group { candidates += songs }
        }
        return candidates
    }

    private func heavyRotation(
        appState: AppState,
        artists: [String],
        recent: Set<String>,
        candidates: [Song],
        day: Date,
        used: Set<String>,
        identities: Set<String>
    ) async -> Mix? {
        guard !artists.isEmpty, !candidates.isEmpty else { return nil }

        var generator = MixEngine.DayRandom(day: day, salt: 1)
        // This week's listening goes to the back rather than being thrown out. Filtering
        // it out was the bug: the top artists are precisely the ones just played, so on an
        // active week the filter could take the pool below the minimum and the mix
        // vanished entirely — worse than showing a track heard on Tuesday.
        let ordered = candidates.filter { !recent.contains($0.id) }
            + candidates.filter { recent.contains($0.id) }
        let chosen = MixEngine.choose(
            from: ordered,
            limit: 25,
            perArtist: 3,
            excluding: used,
            usedIdentities: identities,
            using: &generator
        )

        await Diagnostics.shared.record(
            "mixes",
            "heavy: \(artists.count) artists, \(candidates.count) candidates, \(chosen.count) chosen"
        )
        guard chosen.count >= Self.minimumTracks else { return nil }

        return Mix(
            id: "heavy",
            title: "Heavy Rotation",
            subtitle: artists.prefix(3).joined(separator: ", "),
            songs: chosen
        )
    }

    /// The genres someone actually listens to, not the biggest ones in the library.
    private func topGenres(
        appState: AppState,
        samples: [MixEngine.Sample],
        candidates: [Song],
        scope: LibraryScope,
        limit: Int
    ) async -> [String] {
        let scored = await Task.detached(priority: .userInitiated) {
            MixEngine.ranked(MixEngine.genreScores(samples), limit: limit)
        }.value
        if !scored.isEmpty { return scored }

        // Cold start: the play log has no genres yet, but the tracks by favourite artists
        // do, so the most common genre among those is still a personal answer and costs
        // nothing extra.
        var counts: [String: Int] = [:]
        for genre in candidates.compactMap(\.genre) where !genre.isEmpty {
            counts[genre, default: 0] += 1
        }
        let fromCandidates = counts
            .sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .prefix(limit)
            .map(\.key)
        if !fromCandidates.isEmpty { return fromCandidates }

        // Nothing at all to go on: the library's own biggest genres.
        let genres = (try? await appState.client.genres(scope: scope)) ?? []
        return genres
            .sorted { ($0.songCount ?? 0) > ($1.songCount ?? 0) }
            .prefix(limit)
            .map(\.value)
    }

    private func genreMix(
        appState: AppState,
        genre: String,
        index: Int,
        unplayedOnly: Bool,
        scope: LibraryScope,
        day: Date,
        used: Set<String>,
        identities: Set<String>
    ) async -> Mix? {
        var pool = (try? await appState.client.songsByGenre(genre, count: 300, scope: scope)) ?? []
        guard !pool.isEmpty else {
            await Diagnostics.shared.record("mixes", "genre: “\(genre)” returned nothing")
            return nil
        }
        // The unheard variant of a genre you already like is a different shelf from the
        // genre itself, and in a library where 95% has never been played it is usually the
        // bigger of the two.
        if unplayedOnly {
            pool = pool.filter { ($0.playCount ?? 0) == 0 }
        }

        var generator = MixEngine.DayRandom(day: day, salt: UInt64(200 + index))
        let chosen = MixEngine.choose(
            from: pool,
            limit: 25,
            perArtist: 2,
            excluding: used,
            usedIdentities: identities,
            using: &generator
        )
        await Diagnostics.shared.record(
            "mixes",
            "genre “\(genre)”\(unplayedOnly ? " (unheard)" : ""): \(pool.count) candidates, \(chosen.count) chosen"
        )
        guard chosen.count >= Self.minimumTracks else { return nil }

        // Named for the genre, because "Shoegaze Mix" says something and "Mix 2" does not.
        return Mix(
            id: "genre-\(index)",
            title: "\(genre) Mix",
            subtitle: "From your \(genre.lowercased()) corner",
            songs: chosen
        )
    }

    /// The only feature in the app that deliberately goes looking in the ~24,500 tracks
    /// that have never been played once.
    private func newToYou(
        appState: AppState,
        samples: [MixEngine.Sample],
        scope: LibraryScope,
        day: Date,
        used: Set<String>,
        identities: Set<String>
    ) async -> Mix? {
        var pool: [Song] = []

        let seedIDs = await Task.detached(priority: .userInitiated) { Self.seeds(from: samples) }.value
        for seed in seedIDs {
            let similar = (try? await appState.client.similarSongs(toSongID: seed, count: 50)) ?? []
            pool += similar
        }
        pool = pool.filter { ($0.playCount ?? 0) == 0 }

        // `getSimilarSongs2` gave 19 rows for a seed here, eleven of them unplayed, so
        // three seeds do not fill a mix on their own. Random songs do, and with 95% of the
        // library never played the filter barely costs anything.
        if pool.count < 25 {
            let random = (try? await appState.client.randomSongs(size: 200, scope: scope)) ?? []
            pool += random.filter { ($0.playCount ?? 0) == 0 }
        }
        guard !pool.isEmpty else {
            await Diagnostics.shared.record("mixes", "new: no never-played candidates came back")
            return nil
        }

        var generator = MixEngine.DayRandom(day: day, salt: 3)
        let chosen = MixEngine.choose(
            from: pool,
            limit: 25,
            perArtist: 2,
            excluding: used,
            usedIdentities: identities,
            using: &generator
        )
        await Diagnostics.shared.record(
            "mixes", "new: \(pool.count) unplayed candidates, \(chosen.count) chosen"
        )
        guard chosen.count >= Self.minimumTracks else { return nil }

        return Mix(
            id: "new",
            title: "New to You",
            subtitle: "Never played, from your own library",
            songs: chosen
        )
    }

    /// Up to three of the most-played tracks, as seeds for similarity.
    ///
    /// Song ids, not artist ids: `getSimilarSongs2` returns nothing for an artist id on
    /// this server, which is already noted where the client method is defined.
    nonisolated private static func seeds(from samples: [MixEngine.Sample]) -> [String] {
        var weights: [String: Double] = [:]
        for sample in samples { weights[sample.songID, default: 0] += sample.weight }
        return MixEngine.ranked(weights, limit: 3)
    }

    /// Marks a mix's tracks as spent, so no later page can use them again.
    private func record(_ songs: [Song]) {
        for song in songs {
            used.insert(song.id)
            identities.insert(MixEngine.identity(song))
        }
    }
}
