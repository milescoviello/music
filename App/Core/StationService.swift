import Foundation
import Observation

/// Starts stations and keeps them going: when one gets within five tracks of its end,
/// the next batch is fetched and added, so it plays for as long as you let it.
@MainActor
@Observable
final class StationService {
    /// The station being started — for a spinner on its card.
    private(set) var starting: Station?

    @ObservationIgnored private weak var appState: AppState?
    @ObservationIgnored private var refilling = false
    @ObservationIgnored private var artistSongs: [String: [Song]] = [:]
    @ObservationIgnored private var yearSpan: ClosedRange<Int>?

    func configure(appState: AppState) {
        self.appState = appState
    }

    // MARK: - Playing

    func play(_ station: Station) {
        guard let appState, starting == nil else { return }
        starting = station
        Task {
            defer { starting = nil }
            let songs = await batch(for: station, after: [])
            guard !songs.isEmpty else { return }
            // Shuffle is never applied on top: each station's order is the point of it,
            // whether that is chronology or a whole album.
            appState.player.play(songs: songs, startingAt: 0, source: station.title, station: station)
        }
    }

    /// Plexamp's Sonic Adventure: from one track to another by way of what is related to
    /// each. Navidrome has no sonic map to walk, so the path is built from the two tracks'
    /// similar songs: those near the start, then those near both, then those near the end.
    func playAdventure(from start: Song, to end: Song) async {
        guard let appState else { return }
        // The real thing, when the sonic analysis has both ends.
        if let path = await appState.sonic.path(from: start, to: end, steps: 12) {
            appState.player.play(
                songs: [start] + path + [end],
                startingAt: 0,
                source: "\(start.title) → \(end.title)",
                station: .adventure(fromID: start.id, toID: end.id)
            )
            return
        }
        let client = appState.client
        async let outgoing = client.similarSongs(toSongID: start.id, count: 30)
        async let incoming = client.similarSongs(toSongID: end.id, count: 30)
        let queue = [start, end]
        let from = GuestDJRules.filter((try? await outgoing) ?? [], queue: queue, generated: [])
        let to = GuestDJRules.filter((try? await incoming) ?? [], queue: queue, generated: [])
        let path = GuestDJRules.bridge(fromRelated: from, toRelated: to, count: 10)
        appState.player.play(
            songs: [start] + path + [end],
            startingAt: 0,
            source: "\(start.title) → \(end.title)",
            station: .adventure(fromID: start.id, toID: end.id)
        )
    }

    // MARK: - Topping up

    func queueChanged() {
        guard let appState, !refilling else { return }
        let queue = appState.player.queue
        guard StationRules.needsRefill(queue), let station = queue.station else { return }

        refilling = true
        Task {
            defer { refilling = false }
            let more = await batch(for: station, after: appState.player.queue.tracks)
            // Still the same station: a new queue may have started while this was fetching.
            guard appState.player.queue.station == station, !more.isEmpty else { return }
            appState.player.append(more)
        }
    }

    // MARK: - Batches

    /// The next tracks for a station, none of them already in `queue`.
    private func batch(for station: Station, after queue: [Song]) async -> [Song] {
        guard let appState else { return [] }
        let client = appState.client
        let scope = appState.scope.scope
        let size = StationRules.batchSize
        let candidates: [Song]

        switch station {
        case .library:
            candidates = (try? await client.randomSongs(size: size, scope: scope)) ?? []

        case .deepCuts:
            candidates = await deepCuts(size: size)

        case .timeTravel:
            candidates = await timeTravel(after: queue.last?.year, size: size)

        case .randomAlbum:
            // A whole album at a time, in its own order: the station's one rule.
            var album: [Song] = []
            for _ in 0..<3 where album.isEmpty {
                guard let pick = (try? await client.albums(type: .random, size: 1, scope: scope))?.first else { break }
                let songs = (try? await client.albumDetail(id: pick.id))?.songs ?? []
                if !songs.contains(where: { song in queue.contains { $0.id == song.id } }) { album = songs }
            }
            return album

        case let .decade(start):
            candidates = (try? await client.randomSongs(size: size, fromYear: start, toYear: start + 9, scope: scope)) ?? []

        case let .genre(name):
            candidates = await appState.radio.genreMix(name, scope: scope, size: size)

        case let .artistMix(ids, _):
            candidates = await artistMix(ids, size: size, isFirst: queue.isEmpty)

        case let .albumMix(ids, _):
            candidates = await albumMix(ids, size: size, after: queue)

        case let .radio(seeds, _):
            candidates = await radio(seeds: seeds, after: queue, size: size)

        case let .mood(tag):
            // The service ranks the whole library by the tag; a station wants a varied
            // draw from the top of that, not the same order every time.
            let ranked = await appState.sonic.tagged(tag, limit: 400) ?? []
            candidates = Array(StationRules.fresh(ranked, excluding: queue).prefix(150).shuffled().prefix(size))

        case .adventure:
            return []
        }

        return StationRules.fresh(candidates, excluding: queue)
    }

    /// The artists played most — from the most-played albums — and the tracks of theirs
    /// played least.
    private func deepCuts(size: Int) async -> [Song] {
        guard let appState else { return [] }
        let client = appState.client
        let scope = appState.scope.scope
        let frequent = (try? await client.albums(type: .frequent, size: 40, scope: scope)) ?? []

        var artists: [String] = []
        for album in frequent {
            if let id = album.artistId, !artists.contains(id) { artists.append(id) }
        }
        guard !artists.isEmpty else {
            let random = (try? await client.randomSongs(size: size * 4, scope: scope)) ?? []
            return StationRules.deepCuts(random.shuffled(), limit: size)
        }

        var lists: [[Song]] = []
        for id in artists.shuffled().prefix(5) {
            let theirs = await songs(byArtist: id).shuffled()
            lists.append(StationRules.deepCuts(theirs, limit: size / 5 + 1))
        }
        return Array(StationRules.interleave(lists).prefix(size))
    }

    private func timeTravel(after year: Int?, size: Int) async -> [Song] {
        guard let appState else { return [] }
        let client = appState.client
        let scope = appState.scope.scope

        if yearSpan == nil {
            let latest = Calendar.current.component(.year, from: .now)
            let oldest = (try? await client.albums(fromYear: 1, toYear: latest, size: 1, scope: scope))?.first?.year
            yearSpan = (oldest ?? 1950)...latest
        }
        guard let span = yearSpan else { return [] }

        // A few spans if the first is empty: a library can skip whole years.
        var cursor = year
        for _ in 0..<12 {
            let years = StationRules.nextTimeTravelSpan(after: cursor, earliest: span.lowerBound, latest: span.upperBound)
            let songs = (try? await client.randomSongs(
                size: size, fromYear: years.lowerBound, toYear: years.upperBound, scope: scope
            )) ?? []
            let ordered = StationRules.chronological(songs)
            if !ordered.isEmpty { return ordered }
            cursor = years.upperBound
        }
        return []
    }

    /// Each artist's own tracks and their similar ones, one artist at a time in turn. The
    /// first batch leans on the artists themselves; later ones on what is like them.
    private func artistMix(_ ids: [String], size: Int, isFirst: Bool) async -> [Song] {
        guard let appState else { return [] }
        let client = appState.client
        let perArtist = max(2, size / max(ids.count, 1))

        var lists: [[Song]] = []
        for id in ids {
            let own = await songs(byArtist: id).shuffled()
            var list = Array(own.prefix(isFirst ? perArtist : perArtist / 2))
            if let seed = own.randomElement() {
                let similar = (try? await client.similarSongs(toSongID: seed.id, count: perArtist)) ?? []
                list = StationRules.interleave([list, similar.shuffled()])
            }
            lists.append(list)
        }
        return Array(StationRules.interleave(lists).prefix(size))
    }

    /// The albums' tracks shuffled together; once they have all played, what is similar
    /// to them.
    private func albumMix(_ ids: [String], size: Int, after queue: [Song]) async -> [Song] {
        guard let appState else { return [] }
        let client = appState.client

        var own: [Song] = []
        for id in ids {
            own += (try? await client.albumDetail(id: id))?.songs ?? []
        }
        let unplayed = StationRules.fresh(own.shuffled(), excluding: queue)
        if !unplayed.isEmpty { return unplayed }

        guard let seed = own.randomElement() else { return [] }
        return (try? await client.similarSongs(toSongID: seed.id, count: size)) ?? []
    }

    /// Related tracks to two seeds at a time: one of the originals and, once something has
    /// played, one of the last few — so the radio stays near where it started and still
    /// moves.
    private func radio(seeds: [String], after queue: [Song], size: Int) async -> [Song] {
        guard let appState else { return [] }
        let client = appState.client
        let recent = queue.suffix(5).map(\.id)

        // Sonic radio, when the analysis is there: around the original seeds and one of the
        // last few played, so it stays near where it started and still moves.
        let sonicSeeds = Array(seeds.shuffled().prefix(3)) + Array(recent.suffix(1))
        if let sonic = await appState.sonic.radio(seeds: sonicSeeds, excluding: queue.map(\.id), limit: size) {
            return sonic
        }

        let picks = [seeds.randomElement(), recent.randomElement()].compactMap { $0 }
        guard !picks.isEmpty else { return [] }

        var lists: [[Song]] = []
        for id in Set(picks) {
            lists.append(((try? await client.similarSongs(toSongID: id, count: size)) ?? []).shuffled())
        }
        let mixed = StationRules.interleave(lists)
        if !mixed.isEmpty { return mixed }
        return (try? await client.randomSongs(size: size, scope: appState.scope.scope)) ?? []
    }

    private func songs(byArtist id: String) async -> [Song] {
        if let known = artistSongs[id] { return known }
        let fetched = (try? await appState?.client.artistSongs(id: id)) ?? []
        artistSongs[id] = fetched
        return fetched
    }
}
