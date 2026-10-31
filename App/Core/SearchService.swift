import Foundation
import Observation

/// Search as both apps do it: what was typed and, when the library would spell it another
/// way, the correction too, merged and ranked.
///
/// The correction comes from `SearchVocabulary`, which is every word in every artist, album
/// and song name. That is fetched with `search3` and an empty query, which this server
/// answers with the whole library, paged -- 56 requests of 500 for 27,898 songs -- once a
/// day at most, on Wi-Fi, and kept on disk. A few hundred kilobytes of words, not songs.
@MainActor
@Observable
final class SearchService {
    struct Outcome: Sendable {
        let query: String
        let results: SearchResult3
        /// What was searched for as well as the query, when it found anything.
        let correction: String?
        /// The query found nothing by itself, so everything shown is the correction's.
        let isCorrectionOnly: Bool

        /// What the results are ranked against, and the top result chosen for.
        var rankedFor: String { isCorrectionOnly ? correction ?? query : query }
    }

    private(set) var vocabulary: SearchVocabulary?

    @ObservationIgnored private weak var appState: AppState?
    @ObservationIgnored private var building: Task<Void, Never>?
    @ObservationIgnored private var loading: Task<Void, Never>?
    private let freshFor: TimeInterval = 24 * 3_600
    private let pageSize = 500
    private let file = Paths.metadata.appendingPathComponent("search-vocabulary.json")

    func configure(appState: AppState) {
        self.appState = appState
        let file = file
        loading = Task { [weak self] in
            let stored = await Task.detached(priority: .utility) { () -> SearchVocabulary? in
                guard let data = try? Data(contentsOf: file) else { return nil }
                return try? JSONDecoder().decode(SearchVocabulary.self, from: data)
            }.value
            guard let self else { return }
            if vocabulary == nil { vocabulary = stored }
            loading = nil
        }
    }

    /// Builds the vocabulary if there is none or it is a day old. Cheap to call often.
    func prepare() {
        guard building == nil, loading == nil, let appState, appState.credentials != nil,
              appState.reachability.network == .wifi
        else { return }
        if let vocabulary, Date.now.timeIntervalSince(vocabulary.builtAt) < freshFor { return }

        let client = appState.client
        let pageSize = pageSize
        let file = file
        building = Task { [weak self] in
            defer { self?.building = nil }
            do {
                let names = try await Self.allNames(client: client, pageSize: pageSize)
                let built = await Task.detached(priority: .utility) { () -> SearchVocabulary in
                    let vocabulary = SearchVocabulary.build(names: names)
                    if let data = try? JSONEncoder().encode(vocabulary) {
                        try? data.write(to: file, options: .atomic)
                    }
                    return vocabulary
                }.value
                self?.vocabulary = built
                await Diagnostics.shared.record("search", "vocabulary: \(built.count) words from \(names.count) names")
            } catch {
                // Kept as it was; the next search tries again.
                if !(error is CancellationError) {
                    await Diagnostics.shared.record("search", "vocabulary not built: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Every artist, album and song name, and every song's artist credit, which carries the
    /// featured artists the artist list does not.
    private nonisolated static func allNames(client: SubsonicClient, pageSize: Int) async throws -> [String] {
        var names: [String] = []
        var offsets = (artists: 0, albums: 0, songs: 0)
        var more = (artists: true, albums: true, songs: true)
        while more.artists || more.albums || more.songs {
            try Task.checkCancellation()
            let page = try await client.search(
                query: "",
                artistCount: more.artists ? pageSize : 0,
                albumCount: more.albums ? pageSize : 0,
                songCount: more.songs ? pageSize : 0,
                artistOffset: offsets.artists,
                albumOffset: offsets.albums,
                songOffset: offsets.songs
            )
            names += page.artists.map(\.name)
            names += page.albums.map(\.name)
            for song in page.songs {
                names.append(song.title)
                if let artist = song.artist { names.append(artist) }
            }
            if more.artists { more.artists = page.artists.count == pageSize; offsets.artists += pageSize }
            if more.albums { more.albums = page.albums.count == pageSize; offsets.albums += pageSize }
            if more.songs { more.songs = page.songs.count == pageSize; offsets.songs += pageSize }
        }
        return names
    }

    /// Nil when neither search reached the server, so a screen can tell offline from
    /// nothing found.
    func search(_ text: String, scope: LibraryScope) async -> Outcome? {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let appState else { return nil }
        prepare()

        let client = appState.client
        let correction = vocabulary?.correction(for: query)
        // This server answers a bare single character with nothing at all -- "k", "a",
        // "x" -- but the same character in quotes as a whole word. Verified: `"k"` finds
        // the songs called "K" and "K.".
        let sent = query.count == 1 ? "\"\(query)\"" : query
        async let typed = Self.fetch(client, sent, scope)
        async let corrected = Self.fetch(client, correction, scope)
        let (typedResults, correctedResults) = await (typed, corrected)
        guard typedResults != nil || correctedResults != nil else { return nil }

        let found = typedResults ?? SearchResult3()
        let foundByCorrection = correctedResults.map { !$0.isEmpty } ?? false
        let isCorrectionOnly = found.isEmpty && foundByCorrection
        let merged = correctedResults.map { found.adding($0) } ?? found
        let rankedFor = isCorrectionOnly ? correction ?? query : query
        return Outcome(
            query: query,
            results: SearchRanking.arranged(merged, for: rankedFor),
            correction: foundByCorrection ? correction : nil,
            isCorrectionOnly: isCorrectionOnly
        )
    }

    private nonisolated static func fetch(_ client: SubsonicClient, _ query: String?, _ scope: LibraryScope) async -> SearchResult3? {
        guard let query else { return nil }
        return try? await client.search(query: query, scope: scope)
    }
}
