import Foundation
#if canImport(FoundationNetworking)
// Linux keeps URLSession here; only the test package ever builds there.
import FoundationNetworking
#endif

/// Our own sonic analysis service (`server/sonic`, running on the 148 host): Plex's sonic
/// analysis, rebuilt.
///
/// Plex computes, per track, the mean of an open MusiCNN tagger's 50 outputs over the
/// whole track in 3-second windows, and answers "sounds like" with cosine distance between
/// those vectors; Plexamp's seekbar draws the track's momentary loudness every 100 ms.
/// The service computes both for every track Navidrome has, keyed by Navidrome's song,
/// album and artist ids, and this is the app's side of it.
///
/// Every call is optional by design: a track not analysed yet answers 404, which is nil
/// here, and a service that cannot be reached is an error the caller treats as "use what
/// Navidrome has instead".
struct SonicClient: Sendable {
    struct Configuration: Codable, Equatable, Sendable {
        var baseURL: URL
        /// Sent as `X-Sonic-Token` when set. The service is LAN-only; this is for a host
        /// that wants one anyway.
        var token: String?

        static let `default` = Configuration(baseURL: URL(string: "http://192.168.1.148:8650")!)
    }

    struct Status: Decodable, Equatable, Sendable {
        /// Tracks Navidrome has.
        let tracks: Int
        /// Tracks with a sonic vector and loudness levels.
        let analysed: Int
        /// Whether an analysis pass is running now.
        let analysing: Bool
        let model: String
        let version: Int
    }

    /// Momentary loudness (BS.1770, 400 ms windows) through the whole track, in LUFS,
    /// floored at −40 — Plex's `/levels`. `hop` is the seconds between readings *before*
    /// subsampling; with `points` asked for, the readings are that many bucket means.
    struct Levels: Decodable, Equatable, Sendable {
        let id: String
        let hop: Double
        let levels: [Float]
    }

    /// Beats, tempo and key — not something Plex has; for beat-matched crossfades.
    ///
    /// `beats` are seconds from the start of the file, from Essentia's multi-feature beat
    /// tracker; `confidence` is its own, 0 to about 5.3, where above 3.5 is excellent,
    /// 1.5–3.5 usable and under 1 not to be trusted. `bpm` is nil and `beats` empty when
    /// no beat was found. `key` is a pitch class ("A", "C#") and `scale` "major" or
    /// "minor". `loudness` is the integrated BS.1770 loudness of the whole track.
    struct Rhythm: Decodable, Equatable, Sendable {
        let id: String
        let bpm: Double?
        let confidence: Double?
        let beats: [Double]
        let key: String?
        let scale: String?
        let keyStrength: Double?
        let duration: Double?
        let loudness: Double?
    }

    struct Neighbour: Decodable, Equatable, Sendable {
        let id: String
        /// Cosine distance, 0 for identical; Plex's "maxDistance" is on this scale.
        let distance: Double
    }

    private struct Items: Decodable {
        let items: [Neighbour]
    }

    var configuration: Configuration
    var session: URLSession = .shared

    // MARK: - Calls

    func status() async throws -> Status {
        try await get("v1/status", as: Status.self)
    }

    /// The seekbar's data. Nil when the track has not been analysed yet.
    func levels(songID: String, points: Int = 128) async throws -> Levels? {
        try await getIfPresent("v1/tracks/\(songID)/levels", ["points": String(points)], as: Levels.self)
    }

    /// Every reading, 100 ms apart: what Sweet Fades measures a streamed track's intro and
    /// outro from without having its file.
    func allLevels(songID: String) async throws -> Levels? {
        try await levels(songID: songID, points: 0)
    }

    /// Nil when the track has not been analysed yet.
    func rhythm(songID: String) async throws -> Rhythm? {
        try await getIfPresent("v1/tracks/\(songID)/rhythm", [:], as: Rhythm.self)
    }

    /// Plexamp's Sonically Similar tracks, nearest first.
    func similarTracks(to songID: String, limit: Int = 50, excludingArtist: Bool = false) async throws -> [Neighbour] {
        try await items("v1/tracks/\(songID)/similar", ["limit": String(limit), "exclude_artist": excludingArtist ? "1" : "0"])
    }

    /// Plexamp's Outside Your Comfort Zone: related, but not close.
    func distantTracks(from songID: String, limit: Int = 50) async throws -> [Neighbour] {
        try await items("v1/tracks/\(songID)/distant", ["limit": String(limit)])
    }

    func similarAlbums(to albumID: String, limit: Int = 20) async throws -> [Neighbour] {
        try await items("v1/albums/\(albumID)/similar", ["limit": String(limit)])
    }

    func similarArtists(to artistID: String, limit: Int = 20) async throws -> [Neighbour] {
        try await items("v1/artists/\(artistID)/similar", ["limit": String(limit)])
    }

    /// Plexamp's Sonic Adventure: the tracks between two, in order, not including either.
    func path(from start: String, to end: String, steps: Int = 10) async throws -> [Neighbour] {
        try await items("v1/path", ["from": start, "to": end, "steps": String(steps)])
    }

    /// A radio around one or more seeds, leaving out what has played.
    func radio(seeds: [String], excluding: [String] = [], limit: Int = 25) async throws -> [Neighbour] {
        try await items("v1/radio", [
            "seed": seeds.joined(separator: ","),
            "exclude": excluding.joined(separator: ","),
            "limit": String(limit),
        ])
    }

    /// The tracks that sound most like one of the model's 50 tags ("chill", "sad",
    /// "party"…), at most two per artist.
    func tagged(_ tag: String, limit: Int = 100) async throws -> [Neighbour] {
        try await items("v1/tags/\(tag)/tracks", ["limit": String(limit)])
    }

    // MARK: - Plumbing

    /// Paths and queries, Foundation-only so they are tested.
    func url(_ path: String, _ query: [String: String] = [:]) -> URL? {
        guard var components = URLComponents(
            url: configuration.baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        ) else { return nil }
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return components.url
    }

    private func items(_ path: String, _ query: [String: String]) async throws -> [Neighbour] {
        try await getIfPresent(path, query, as: Items.self)?.items ?? []
    }

    private func get<T: Decodable>(_ path: String, _ query: [String: String] = [:], as type: T.Type) async throws -> T {
        guard let value = try await getIfPresent(path, query, as: type) else {
            throw SonicError.notFound
        }
        return value
    }

    /// Nil for a 404 — not analysed, or not known — and an error for anything else.
    private func getIfPresent<T: Decodable>(_ path: String, _ query: [String: String], as type: T.Type) async throws -> T? {
        guard let url = url(path, query) else { throw SonicError.badURL }
        var request = URLRequest(url: url, timeoutInterval: 10)
        if let token = configuration.token, !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "X-Sonic-Token")
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return nil }
        guard (200...299).contains(status) else { throw SonicError.status(status) }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

enum SonicError: Error, Equatable {
    case badURL
    case notFound
    case status(Int)
}

/// Plexamp's seekbar shape, from loudness readings in LUFS to bar heights in points —
/// `ProcessLoudnessData` in Plexamp's player, with its constants: readings floored at
/// −35, squared for contrast, normalised, given a 1.2 power curve, and scaled so the
/// loudest point is `maximumHeight` tall.
enum SeekbarShape {
    static let floor: Float = -35
    static let maximumHeight: Float = 35

    static func heights(fromLevels levels: [Float]) -> [Float] {
        var values = levels.map { level -> Float in
            var value = (max(level, floor) - floor) * (100 / -floor)
            value *= value / 100 * 1.5
            return value.isFinite ? value : 3
        }
        if let top = values.max(), top != 0 {
            values = values.map { $0 * (90 / 2.2) / top }
        }
        let curved = values.map { pow($0, 1.2) / 2.4 }
        guard let peak = curved.max(), peak != 0 else { return curved.map { _ in 0 } }
        return curved.map { $0 * (maximumHeight / peak) }
    }

    /// Resamples to `count` points by linear interpolation, as Plexamp does before
    /// drawing, so the curve has the same detail whatever the source had.
    static func interpolate(_ values: [Float], to count: Int) -> [Float] {
        guard count > 0, !values.isEmpty else { return [] }
        guard values.count > 1, count > 1 else { return Array(repeating: values[0], count: count) }
        return (0..<count).map { index in
            let position = Float(index) * Float(values.count - 1) / Float(count - 1)
            let lower = Int(position)
            let upper = min(lower + 1, values.count - 1)
            let fraction = position - Float(lower)
            return values[lower] + (values[upper] - values[lower]) * fraction
        }
    }
}

extension TrackShape {
    /// A track's shape from the sonic service's loudness readings rather than its file:
    /// the first and last `SweetFades.analysedSeconds` of momentary loudness, and the
    /// gated loudness of the whole track — better than the file measurement's, which only
    /// sees the two ends. Nil for a track too short to have both.
    static func fromLevels(_ levels: [Float], hop: Double) -> TrackShape? {
        guard hop > 0, levels.count >= 2 else { return nil }
        let span = max(1, min(levels.count, Int((SweetFades.analysedSeconds / hop).rounded())))
        return TrackShape(
            intro: LoudnessRamp(levels: Array(levels.prefix(span)), hop: hop),
            outro: LoudnessRamp(levels: Array(levels.suffix(span).reversed()), hop: hop),
            measuredLoudness: LoudnessMeter.integrated(levels)
        )
    }
}
