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

    /// A song with a line of lyrics matching a search, and that line.
    struct LyricHit: Decodable, Equatable, Sendable {
        let id: String
        let title: String
        let artist: String
        let line: String
        /// 4 the phrase in one line, 3 across two, 2 every word in one, 1 in the song.
        let score: Int
        /// Milliseconds into the track the line starts, when the lyrics are synced.
        let at: Int?
    }

    private struct LyricHits: Decodable {
        let items: [LyricHit]
    }

    private struct Kept: Decodable {
        let name: String
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

    /// Songs whose stored lyrics have a line like `query`, best first: the service reads
    /// them from Navidrome's database, so this is one request rather than one per track.
    /// Empty from a service too old to have the endpoint, which answers 404.
    func lyricSearch(_ query: String, limit: Int = 20) async throws -> [LyricHit] {
        try await getIfPresent("v1/lyrics/search", ["q": query, "limit": String(limit)], as: LyricHits.self)?.items ?? []
    }

    /// Songs to point plays at by hand: old song id → new, for the ones the history repair
    /// cannot find by name (a translated title, the artist in another script). Kept on the
    /// server in `data/history-links.json`. Empty from a service too old to have them.
    func historyLinks() async throws -> [String: String] {
        try await getIfPresent("v1/history/links", [:], as: HistoryLinks.self)?.links ?? [:]
    }

    private struct HistoryLinks: Decodable {
        var links: [String: String]
    }

    /// A play from the music server's own log: every player's, the plays imported from
    /// Plex among them, each with the moment it started.
    struct ServerPlay: Decodable, Sendable {
        var id: String
        var at: Double
        var songID: String
        var title: String
        var artist: String
        var album: String
        var albumID: String?
        var artistID: String?
        var coverArt: String?
        var duration: Int
        var genres: [String]
    }

    struct ServerPlays: Decodable, Sendable {
        var plays: [ServerPlay]
        /// The cursor for the next page: a row of the log, not a time.
        var after: Int
        var more: Bool
    }

    /// `user`'s plays in the server's log after row `after`, oldest row first. Nil from a
    /// service too old to have the log.
    func serverPlays(after: Int, user: String) async throws -> ServerPlays? {
        try await getIfPresent("v1/history/plays", ["after": String(after), "user": user], as: ServerPlays.self)
    }

    /// Hands a Send Logs report to the service, which keeps it as a file in its `data/logs`
    /// on the server. Returns the file's name. A service too old to take one answers 404.
    func sendLogs(_ text: String, source: String) async throws -> String {
        guard let request = logsRequest(text, source: source) else { throw SonicError.badURL }
        let (data, response) = try await session.fetch(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else { throw SonicError.status(status) }
        return (try? JSONDecoder().decode(Kept.self, from: data))?.name ?? ""
    }

    func logsRequest(_ text: String, source: String) -> URLRequest? {
        guard let url = url("v1/logs") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.httpBody = Data(text.utf8)
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(source, forHTTPHeaderField: "X-Log-Source")
        authorise(&request)
        return request
    }

    // MARK: - Lyrics, for the desktop

    private struct LyricLines: Encodable {
        var lines: [String]
        var language: String?
    }

    private struct ReadingLines: Decodable {
        var lines: [[Romanizer.Token]]
    }

    private struct TranslatedLines: Decodable {
        var lines: [String]?
        var draft: Bool?
        var error: String?
    }

    /// Japanese lines as words with their readings, for `Romanizer.romanize(tokens:)`.
    func readings(_ lines: [String]) async throws -> [[Romanizer.Token]] {
        let (data, status) = try await post("v1/lyrics/readings", LyricLines(lines: lines))
        guard status == 200 else { throw status == 404 ? SonicError.notFound : SonicError.status(status) }
        let readings = try JSONDecoder().decode(ReadingLines.self, from: data).lines
        guard readings.count == lines.count else { throw SonicError.status(status) }
        return readings
    }

    enum Translation: Equatable, Sendable {
        /// `draft`: the quick offline model's, which the service replaces with its local
        /// model's when the server is quiet. Shown, not kept.
        case done([String], draft: Bool)
        /// Started, or still going: ask again in a few seconds.
        case translating
        case failed(String)
    }

    /// One English line per line, from the service's local model. The first ask starts
    /// the work; it can take a minute or two on a busy server, and is kept after.
    func translate(_ lines: [String], language: String) async throws -> Translation {
        let (data, status) = try await post("v1/lyrics/translate", LyricLines(lines: lines, language: language))
        let answer = try? JSONDecoder().decode(TranslatedLines.self, from: data)
        switch status {
        case 200:
            guard let english = answer?.lines, english.count == lines.count else { throw SonicError.status(status) }
            return .done(english, draft: answer?.draft == true)
        case 202: return .translating
        case 503: return .failed(answer?.error ?? "The translator isn't working.")
        case 404: throw SonicError.notFound
        default: throw SonicError.status(status)
        }
    }

    // MARK: - Lyrics fixed by hand

    /// The app's Subsonic sign-in, which the service asks Navidrome about: only an admin
    /// may write into the library's files.
    struct SignIn: Encodable, Sendable {
        var u: String
        var t: String
        var s: String
    }

    private struct LyricsSave: Encodable {
        struct Line: Encodable {
            /// Nil for lyrics saved as words alone.
            var start: Int?
            var value: String
        }

        var id: String
        var original: [String]
        var synced: Bool
        var lines: [Line]
        var auth: SignIn
    }

    private struct Refusal: Decodable {
        var error: String?
    }

    /// Lyrics timed by hand, into the song's own file on the server, in place of the
    /// lyrics they were made from. Throws `LyricsSaveError` with the service's reason.
    func saveLyrics(songID: String, timing: LyricsTiming, signIn: SignIn) async throws {
        guard timing.canSave else {
            throw LyricsSaveError(message: "Every line needs a time before the lyrics can be saved.")
        }
        let lines = timing.lines.map { LyricsSave.Line(start: timing.isComplete ? $0.start : nil, value: $0.value) }
        let body = LyricsSave(
            id: songID, original: timing.original, synced: timing.wasSynced, lines: lines, auth: signIn
        )
        // Long: the service copies the file, checks its audio and puts it back, which for
        // a long hi-res track over the share is several seconds.
        let (data, status) = try await post("v1/lyrics/save", body, timeout: 120)
        guard status == 200 else {
            let reason = try? JSONDecoder().decode(Refusal.self, from: data).error
            switch status {
            case 404 where reason == "no such endpoint":
                throw LyricsSaveError(message: "The sonic service is too old to save lyrics. Update it on the server.")
            default:
                throw LyricsSaveError(message: reason ?? "The sonic service answered \(status).")
            }
        }
    }

    // MARK: - Albums in both libraries

    /// An album held in both libraries, its copies weakest first (`duplicates.py`).
    struct DuplicateAlbum: Decodable, Sendable, Identifiable, Hashable {
        struct Copy: Decodable, Sendable, Identifiable, Hashable {
            var albumId: String
            var name: String
            var artist: String
            var library: String
            var tracks: Int
            var format: String
            var size: Int64
            var plays: Int
            var year: Int?
            var folder: String
            var lossless: Bool
            var id: String { albumId }
        }

        var name: String
        var artist: String
        /// Every copy the same format, depth, rate and track count.
        var alike: Bool
        var copies: [Copy]
        var id: String { copies.map(\.albumId).joined(separator: "+") }
    }

    private struct DuplicateList: Decodable {
        var items: [DuplicateAlbum]
    }

    func duplicateAlbums() async throws -> [DuplicateAlbum] {
        try await get("v1/library/duplicates", as: DuplicateList.self).items
    }

    // MARK: - Shows near home

    /// A concert by an artist played lots, near home (`shows.py`).
    struct Show: Decodable, Sendable, Identifiable, Hashable {
        var id: String
        var artist: String
        var name: String
        /// "2026-12-05", the venue's own date.
        var date: String
        /// "20:00:00", when it is known.
        var time: String?
        var venue: String
        var city: String
        var url: String
        var image: String?
    }

    private struct ShowList: Decodable {
        var items: [Show]
    }

    /// Nil when the service has no Ticketmaster key: no shelf.
    func shows() async throws -> [Show]? {
        try await getIfPresent("v1/shows", [:], as: ShowList.self)?.items
    }

    // MARK: - Word by word

    /// A line of lyrics as LRCLIB times it word by word (`wordsync.py`), in milliseconds.
    struct WordLine: Decodable, Sendable, Equatable {
        struct Word: Decodable, Sendable, Equatable {
            var start: Int
            var text: String
        }

        var start: Int
        var end: Int
        var text: String
        var words: [Word]
    }

    private struct WordList: Decodable {
        var lines: [WordLine]
    }

    /// Nil when there is no word timing to be had for the song.
    func words(songID: String) async throws -> [WordLine]? {
        try await getIfPresent("v1/lyrics/\(songID)/words", [:], as: WordList.self)?.lines
    }

    // MARK: - Lyrics for a song with none

    private struct LyricsFind: Encodable {
        var id: String
        var auth: SignIn
    }

    private struct FindAnswer: Decodable {
        var found: Bool
        var instrumental: Bool?
        var synced: Bool?
        var lines: [LyricLine]?
    }

    enum FoundLyrics: Equatable, Sendable {
        /// Found, and saved beside the song as a `.lrc`.
        case found(StructuredLyrics)
        /// Nothing on LRCLIB for this recording.
        case notFound
        /// LRCLIB has the song as an instrumental: no words to find.
        case instrumental
    }

    /// LRCLIB's lyrics for a song that has none, which the service saves beside the song.
    /// Throws `LyricsSaveError` with the service's reason.
    func findLyrics(songID: String, signIn: SignIn) async throws -> FoundLyrics {
        let (data, status) = try await post("v1/lyrics/find", LyricsFind(id: songID, auth: signIn), timeout: 60)
        guard status == 200 else {
            let reason = try? JSONDecoder().decode(Refusal.self, from: data).error
            if status == 404, reason == "no such endpoint" {
                throw LyricsSaveError(message: "The sonic service is too old to find lyrics. Update it on the server.")
            }
            throw LyricsSaveError(message: reason ?? "The sonic service answered \(status).")
        }
        let answer = try JSONDecoder().decode(FindAnswer.self, from: data)
        guard answer.found, let lines = answer.lines, !lines.isEmpty else {
            return answer.instrumental == true ? .instrumental : .notFound
        }
        return .found(StructuredLyrics(synced: answer.synced == true, line: lines))
    }

    private func post<Body: Encodable>(_ path: String, _ body: Body, timeout: TimeInterval = 20) async throws -> (Data, Int) {
        guard let url = url(path) else { throw SonicError.badURL }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorise(&request)
        let (data, response) = try await session.fetch(request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    // MARK: - Taste, shared between devices

    /// A play or a skip as one device recorded it, for the others. Times are seconds since
    /// 1970, so the service needs no date format.
    struct TasteEvent: Codable, Sendable, Equatable {
        var id: String
        var kind: String
        var at: Double
        var songID: String
        var title: String
        var artist: String
        var album: String?
        var genre: String?
        var duration: Int?
        var position: Double?
        var albumID: String?
        var artistID: String?
        var coverArt: String?
    }

    struct TastePage: Decodable, Sendable {
        var events: [TasteEvent]
        var seq: Int
    }

    private struct TasteBatch: Encodable {
        var device: String
        var events: [TasteEvent]
    }

    func pushTaste(device: String, events: [TasteEvent]) async throws {
        guard !TestCopy.isOn else { return }
        guard let url = url("v1/taste") else { throw SonicError.badURL }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(TasteBatch(device: device, events: events))
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorise(&request)
        let (_, response) = try await session.fetch(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else { throw SonicError.status(status) }
    }

    /// The other devices' events after `since`.
    func pullTaste(device: String, since: Int) async throws -> TastePage {
        try await get("v1/taste", ["device": device, "since": String(since)], as: TastePage.self)
    }

    // MARK: - Release radar

    struct RadarItem: Decodable, Sendable, Identifiable, Hashable {
        var id: String
        var artist: String
        var title: String
        var type: String
        /// `yyyy-mm-dd`.
        var date: String
        var upcoming: Bool
        var cover: URL?
        /// The cover through the service, which fetches it from the archive once: the
        /// archive's own address redirects to archive.org, which some networks refuse.
        var coverPath: String?
    }

    struct Radar: Decodable, Sendable {
        var items: [RadarItem]
        var updated: Double?
        var refreshing: Bool
    }

    func radar() async throws -> Radar {
        try await get("v1/radar", as: Radar.self)
    }

    /// A release's cover image, through the service. Nil when it has none.
    func radarCover(_ item: RadarItem) async -> Data? {
        guard let path = item.coverPath, let url = url(path) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 30)
        authorise(&request)
        guard let (data, response) = try? await session.fetch(request),
              (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty
        else { return nil }
        return data
    }

    // MARK: - Plumbing

    private func authorise(_ request: inout URLRequest) {
        if let token = configuration.token, !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "X-Sonic-Token")
        }
    }

    /// Paths and queries, Foundation-only so they are tested.
    func url(_ path: String, _ query: [String: String] = [:]) -> URL? {
        guard var components = URLComponents(
            url: configuration.baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        ) else { return nil }
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            // `URLComponents` leaves a "+" as it is, and the service reads one in a query as
            // a space, so a lyric search for "1+1" looked for "1 1".
            if let encoded = components.percentEncodedQuery {
                components.percentEncodedQuery = encoded.replacingOccurrences(of: "+", with: "%2B")
            }
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
        authorise(&request)
        let (data, response) = try await session.fetch(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return nil }
        guard (200...299).contains(status) else { throw SonicError.status(status) }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

/// Why lyrics were not saved, in words to show.
struct LyricsSaveError: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

enum SonicError: Error, Equatable {
    case badURL
    case notFound
    case status(Int)

    /// Whether a failure is the service's as a whole — not reached, not let in, or
    /// failing — rather than about the one track asked after.
    ///
    /// A reply that arrived but could not be read is about that track alone. The service
    /// once sent `NaN` in the levels of every 96 kHz track, 2,887 of them, and a reply
    /// with `NaN` is not JSON; taken for the service being down, any one of those tracks
    /// blanked every seekbar for the two minutes after it.
    static func isServiceWide(_ error: any Error) -> Bool {
        if let error = error as? URLError { return error.code != .cancelled }
        if (error as NSError).domain == NSURLErrorDomain { return true }
        guard let error = error as? SonicError else { return false }
        switch error {
        case .badURL: return true
        case .notFound: return false
        case .status(let code): return code >= 500 || code == 401 || code == 403
        }
    }
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
