import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Getting music into the library from the app: no Hermes in between.
///
/// The catalog is the sonic service's: YouTube Music's songs and albums for a search, an
/// artist's official albums and EPs from MusicBrainz, each marked with whether the library
/// has it. A request is `music-grab serve`'s, on the server beside Navidrome, which sonic
/// relays to: it finds a lossless copy on Soulseek -- never anything lossy -- downloads it,
/// checks it, adds it and fetches its lyrics. The app asks, watches, and can pick the copy.
extension SonicClient {
    struct CatalogSong: Decodable, Equatable, Sendable, Identifiable {
        let title: String
        let artist: String
        let artists: [String]
        let album: String?
        let albumId: String?
        let seconds: Int?
        let videoId: String?
        let cover: URL?
        /// The library has it already.
        let have: Bool

        var id: String { videoId ?? "\(artist)\u{1F}\(title)" }
    }

    struct CatalogAlbum: Decodable, Equatable, Sendable, Identifiable {
        let title: String
        let artist: String
        let artists: [String]
        let year: String?
        /// "Album", "EP", "Single".
        let type: String
        let albumId: String
        let cover: URL?
        let have: Bool

        var id: String { albumId }
    }

    struct CatalogResults: Decodable, Equatable, Sendable {
        let songs: [CatalogSong]
        let albums: [CatalogAlbum]
    }

    /// One of an artist's own albums or EPs, as MusicBrainz lists it.
    struct CatalogRecord: Decodable, Equatable, Sendable, Identifiable {
        let title: String
        let type: String
        let year: String?
        let mbid: String?
        let have: Bool

        var id: String { mbid ?? title }
    }

    struct CatalogDiscography: Decodable, Equatable, Sendable {
        let artist: String?
        let albums: [CatalogRecord]
    }

    /// What is asked for. The library is "music" or "my_music"; `choose` stops after the
    /// search, for a copy to be picked; `albumToo` gets a song's album after it.
    struct GrabAsk: Encodable, Equatable, Sendable {
        var kind: Kind
        var artist: String
        var title: String
        var library: Library
        var choose = false
        var album: String?
        var albumId: String?
        var albumToo = false
        var year: String?
        var tracks: Int?
        var length: Int?
        /// A song in the library whose file is lossy, to be put right in place.
        var replace: String?
        var videoId: String?

        enum Kind: String, Encodable, Sendable { case song, album }

        enum CodingKeys: String, CodingKey {
            case kind, artist, title, library, choose, album, albumId, year, tracks, length, replace
            case albumToo = "album_too"
            case videoId = "video_id"
        }
    }

    enum Library: String, Codable, CaseIterable, Sendable {
        case music
        case myMusic = "my_music"
    }

    struct GrabProgress: Decodable, Equatable, Sendable {
        let done: Int64
        let total: Int64

        var fraction: Double { total > 0 ? min(1, Double(done) / Double(total)) : 0 }
    }

    /// A copy found on Soulseek: one sharer's folder (or file, for a song).
    struct GrabCopy: Decodable, Equatable, Sendable, Identifiable {
        let index: Int
        let peer: String
        let folder: String
        let tracks: Int
        let bytes: Int64
        let free: Bool?
        let queue: Int?
        /// Bytes a second, as the sharer reports it.
        let speed: Double?
        let formats: [String]
        let files: [GrabFile]

        var id: Int { index }
    }

    struct GrabFile: Decodable, Equatable, Sendable {
        let name: String
        let bytes: Int64
        let seconds: Int
    }

    /// Where a request stands. `choosing` waits for a copy to be picked.
    enum GrabState: String, Decodable, Sendable {
        case searching, choosing, queued, downloading, importing, done, failed, cancelled

        /// Still going, so worth watching.
        var isActive: Bool { [.searching, .queued, .downloading, .importing].contains(self) }

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = GrabState(rawValue: raw) ?? .failed
        }
    }

    struct GrabTarget: Decodable, Equatable, Sendable, Identifiable {
        let key: String
        let kind: String
        let artist: String
        let title: String
        let state: GrabState
        let detail: String
        let choice: Int?
        let progress: GrabProgress?
        /// Every copy found: only in one request's own answer. The list has the count.
        let copies: [GrabCopy]
        let copyCount: Int

        var id: String { key }

        enum CodingKeys: String, CodingKey {
            case key, kind, artist, title, state, detail, choice, progress, copies
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            key = try c.decode(String.self, forKey: .key)
            kind = try c.decode(String.self, forKey: .kind)
            artist = try c.decode(String.self, forKey: .artist)
            title = try c.decode(String.self, forKey: .title)
            state = try c.decode(GrabState.self, forKey: .state)
            detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
            choice = try c.decodeIfPresent(Int.self, forKey: .choice)
            progress = try c.decodeIfPresent(GrabProgress.self, forKey: .progress)
            if let all = try? c.decode([GrabCopy].self, forKey: .copies) {
                copies = all
                copyCount = all.count
            } else {
                copies = []
                copyCount = (try? c.decode(Int.self, forKey: .copies)) ?? 0
            }
        }
    }

    struct GrabRequest: Decodable, Equatable, Sendable, Identifiable {
        let id: String
        let created: Double?
        let library: Library
        let kind: String?
        let artist: String?
        let title: String?
        let choose: Bool
        let state: GrabState
        let targets: [GrabTarget]
        let progress: GrabProgress?

        var createdAt: Date? { created.map { Date(timeIntervalSince1970: $0) } }
        /// What the row says under the title: the first target still going, else the first.
        var detail: String {
            (targets.first { $0.state == state } ?? targets.first)?.detail ?? ""
        }
    }

    private struct GrabList: Decodable {
        let items: [GrabRequest]
    }

    private struct Problem: Decodable {
        let error: String
    }

    /// Why a request was not taken, in words to show.
    struct GrabError: LocalizedError, Equatable {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: - Calls

    func catalogSearch(_ query: String, limit: Int = 12) async throws -> CatalogResults {
        guard let found = try await getIfPresent("v1/catalog/search", ["q": query, "limit": String(limit)],
                                                 as: CatalogResults.self, timeout: 20) else {
            throw SonicError.notFound
        }
        return found
    }

    /// An artist's albums and EPs. `artistID` is Navidrome's, whose MusicBrainz id the
    /// service looks up; the name is for an artist without one.
    func catalogArtist(artistID: String, name: String) async throws -> CatalogDiscography {
        guard let found = try await getIfPresent("v1/catalog/artist", ["id": artistID, "name": name],
                                                 as: CatalogDiscography.self, timeout: 40) else {
            throw SonicError.notFound
        }
        return found
    }

    /// Whether requests can be made: the service relays to music-grab, which answers.
    func grabAvailable() async -> Bool {
        (try? await getIfPresent("v1/grab/health", [:], as: [String: Bool].self, timeout: 6))?["ok"] == true
    }

    func grabRequests() async throws -> [GrabRequest] {
        try await getIfPresent("v1/grab/requests", [:], as: GrabList.self)?.items ?? []
    }

    /// One request, with every copy found for it.
    func grabRequest(_ id: String) async throws -> GrabRequest? {
        try await getIfPresent("v1/grab/requests/\(id)", [:], as: GrabRequest.self)
    }

    func ask(_ ask: GrabAsk) async throws -> GrabRequest {
        try await grabPost("v1/grab/requests", ask)
    }

    func choose(request id: String, target: String, copy: Int) async throws -> GrabRequest {
        struct Choice: Encodable { let target: String; let choice: Int }
        return try await grabPost("v1/grab/requests/\(id)/choose", Choice(target: target, choice: copy))
    }

    func retry(request id: String) async throws -> GrabRequest {
        try await grabPost("v1/grab/requests/\(id)/retry", [String: String]())
    }

    func cancel(request id: String) async throws -> GrabRequest {
        try await grabPost("v1/grab/requests/\(id)/cancel", [String: String]())
    }

    private func grabPost<Body: Encodable>(_ path: String, _ body: Body) async throws -> GrabRequest {
        let (data, status) = try await post(path, body, timeout: 40)
        guard (200...299).contains(status) else {
            if let problem = try? JSONDecoder().decode(Problem.self, from: data) {
                throw GrabError(message: problem.error.prefix(1).uppercased() + problem.error.dropFirst())
            }
            throw SonicError.status(status)
        }
        return try JSONDecoder().decode(GrabRequest.self, from: data)
    }
}
