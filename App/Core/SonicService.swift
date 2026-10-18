import Foundation
import Observation

/// The app's view of our sonic analysis service: whether it is there, and its answers as
/// songs, albums and artists rather than ids.
///
/// Every method returns nil when the service cannot answer — not set up, unreachable, or
/// the track not analysed yet — and callers fall back to what Navidrome offers
/// (`getSimilarSongs2`, artist similarity through its agents). So nothing in the app
/// depends on the service; it only gets better when it is there.
@MainActor
@Observable
final class SonicService {
    private static let configurationKey = "sonic.configuration"

    private(set) var status: SonicClient.Status?
    /// Set when the last status check failed, for the settings screen.
    private(set) var lastError: String?

    var configuration: SonicClient.Configuration {
        didSet {
            if let data = try? JSONEncoder().encode(configuration) {
                UserDefaults.standard.set(data, forKey: Self.configurationKey)
            }
            Task { await refreshStatus() }
        }
    }

    /// Whether the sonic features should ask the service at all. True once a status check
    /// has succeeded and something has been analysed.
    var isAvailable: Bool { (status?.analysed ?? 0) > 0 }

    @ObservationIgnored private weak var appState: AppState?
    @ObservationIgnored private var songs: [String: Song] = [:]
    @ObservationIgnored private var shapes: [String: TrackShape] = [:]
    @ObservationIgnored private var fetchingShapes: Set<String> = []
    @ObservationIgnored private var lastCheck: Date?

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.configurationKey),
           let stored = try? JSONDecoder().decode(SonicClient.Configuration.self, from: data) {
            configuration = stored
        } else {
            configuration = .default
        }
    }

    func configure(appState: AppState) {
        self.appState = appState
    }

    private var client: SonicClient { SonicClient(configuration: configuration) }

    // MARK: - Status

    /// Cheap enough to call on launch and on every foreground; it checks at most once a
    /// minute unless forced.
    func refreshStatus(force: Bool = false) async {
        if !force, let lastCheck, Date.now.timeIntervalSince(lastCheck) < 60 { return }
        lastCheck = .now
        do {
            status = try await client.status()
            lastError = nil
        } catch {
            status = nil
            lastError = error.localizedDescription
        }
    }

    // MARK: - Tracks

    /// Plexamp's Sonically Similar tracks.
    func similarSongs(to song: Song, limit: Int = 50, excludingArtist: Bool = false, maxDistance: Double? = nil) async -> [Song]? {
        guard isAvailable else { return nil }
        guard var hits = try? await client.similarTracks(to: song.id, limit: limit, excludingArtist: excludingArtist),
              !hits.isEmpty
        else { return nil }
        if let maxDistance { hits = hits.filter { $0.distance <= maxDistance } }
        return await hydrate(hits.map(\.id))
    }

    /// Plexamp's Outside Your Comfort Zone.
    func distantSongs(from song: Song, limit: Int = 50) async -> [Song]? {
        guard isAvailable, let hits = try? await client.distantTracks(from: song.id, limit: limit), !hits.isEmpty
        else { return nil }
        return await hydrate(hits.map(\.id))
    }

    /// A radio around the seeds' shared sound, leaving out what is already queued.
    func radio(seeds: [String], excluding: [String] = [], limit: Int = 25) async -> [Song]? {
        guard isAvailable, !seeds.isEmpty,
              let hits = try? await client.radio(seeds: seeds, excluding: excluding, limit: limit), !hits.isEmpty
        else { return nil }
        return await hydrate(hits.map(\.id))
    }

    /// Plexamp's Sonic Adventure: the tracks between two, in order.
    func path(from start: Song, to end: Song, steps: Int = 10) async -> [Song]? {
        guard isAvailable, let hits = try? await client.path(from: start.id, to: end.id, steps: steps), !hits.isEmpty
        else { return nil }
        return await hydrate(hits.map(\.id))
    }

    /// The tracks that sound most like one of the model's tags — a mood station.
    func tagged(_ tag: String, limit: Int = 100) async -> [Song]? {
        guard isAvailable, let hits = try? await client.tagged(tag, limit: limit), !hits.isEmpty else { return nil }
        return await hydrate(hits.map(\.id))
    }

    // MARK: - Albums and artists

    func similarAlbums(to albumID: String, limit: Int = 12) async -> [Album]? {
        guard isAvailable, let appState,
              let hits = try? await client.similarAlbums(to: albumID, limit: limit), !hits.isEmpty
        else { return nil }
        let api = appState.client
        let found = await ordered(hits.map(\.id)) { id in try? await api.albumDetail(id: id).summary }
        return found.isEmpty ? nil : found
    }

    func similarArtists(to artistID: String, limit: Int = 15) async -> [Artist]? {
        guard isAvailable, let appState,
              let hits = try? await client.similarArtists(to: artistID, limit: limit), !hits.isEmpty
        else { return nil }
        let api = appState.client
        let found = await ordered(hits.map(\.id)) { id -> Artist? in
            guard let detail = try? await api.artistDetail(id: id) else { return nil }
            var artist = Artist(id: detail.id, name: detail.name)
            artist.coverArt = detail.coverArt
            artist.albumCount = detail.albumCount
            return artist
        }
        return found.isEmpty ? nil : found
    }

    // MARK: - Shapes for Sweet Fades

    /// A streamed track's intro and outro, from the service's loudness readings — so its
    /// fades are measured like a cached track's, without having the file.
    func shape(for songID: String) -> TrackShape? {
        shapes[songID]
    }

    /// Fetches the shapes of tracks that will be faded soon, once each. `onMissing` hears
    /// of each one the service cannot give — not analysed yet, or no service to ask — so
    /// the caller can measure it some other way.
    func prefetchShapes(
        for songs: [Song],
        onShape: @escaping @MainActor (String) -> Void,
        onMissing: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        guard isAvailable else {
            for song in songs where shapes[song.id] == nil { onMissing(song.id) }
            return
        }
        let client = client
        for song in songs where shapes[song.id] == nil && !fetchingShapes.contains(song.id) {
            fetchingShapes.insert(song.id)
            let id = song.id
            Task {
                defer { fetchingShapes.remove(id) }
                guard let levels = try? await client.allLevels(songID: id),
                      let shape = TrackShape.fromLevels(levels.levels, hop: levels.hop)
                else {
                    onMissing(id)
                    return
                }
                shapes[id] = shape
                onShape(id)
            }
        }
    }

    // MARK: - Hydration

    /// Songs for ids, in the service's order, each fetched once and remembered.
    private func hydrate(_ ids: [String]) async -> [Song]? {
        guard let appState else { return nil }
        let api = appState.client
        let missing = ids.filter { songs[$0] == nil }
        let fetched = await ordered(missing) { id in try? await api.song(id: id) }
        for song in fetched { songs[song.id] = song }
        let result = ids.compactMap { songs[$0] }
        return result.isEmpty ? nil : result
    }

    /// Runs `fetch` for every id at once and keeps the answers in the ids' order.
    private func ordered<T: Sendable>(_ ids: [String], _ fetch: @escaping @Sendable (String) async -> T?) async -> [T] {
        var found: [Int: T] = [:]
        await withTaskGroup(of: (Int, T?).self) { group in
            for (offset, id) in ids.enumerated() {
                group.addTask { (offset, await fetch(id)) }
            }
            for await (offset, value) in group {
                if let value { found[offset] = value }
            }
        }
        return ids.indices.compactMap { found[$0] }
    }
}
