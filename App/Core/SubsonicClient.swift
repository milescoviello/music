#if canImport(CryptoKit)
import CryptoKit
#endif
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Builds authenticated URLs for endpoints that return *media* rather than JSON.
///
/// Media URLs are handed to `AVPlayer` and to the artwork cache, both of which key
/// on the URL. The salt is therefore fixed for the life of the session: a fresh
/// salt per call would produce a different URL for the same image on every access,
/// so nothing would ever cache-hit and `AVPlayer` would re-authenticate on every
/// seek. Same cryptographic value either way -- both are `MD5(password + salt)`
/// over cleartext on a LAN -- but these URLs are stable and cacheable.
struct SubsonicSigner: Sendable {
    let baseURL: URL
    let username: String
    private let salt: String
    private let token: String

    init(credentials: SubsonicClient.Credentials) {
        baseURL = credentials.baseURL
        username = credentials.username
        salt = SubsonicAuth.makeSalt()
        token = SubsonicAuth.token(password: credentials.password, salt: salt)
    }

    func url(_ endpoint: String, _ query: [String: String?] = [:]) -> URL? {
        SubsonicAuth.buildURL(
            baseURL: baseURL,
            endpoint: endpoint,
            username: username,
            token: token,
            salt: salt,
            query: query
        )
    }
}

enum SubsonicAuth {
    static let clientName = "Music"
    static let apiVersion = "1.16.1"

    static func makeSalt() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12))
    }

    /// Subsonic mandates a salted MD5. MD5 is not a choice we are making here.
    static func token(password: String, salt: String) -> String {
        Insecure.MD5
            .hash(data: Data((password + salt).utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func buildURL(
        baseURL: URL,
        endpoint: String,
        username: String,
        token: String,
        salt: String,
        query: [String: String?],
        // Repeated parameters -- `songId=a&songId=b` -- which a dictionary cannot
        // express and `createPlaylist`/`updatePlaylist` are defined in terms of.
        repeated: [URLQueryItem] = []
    ) -> URL? {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("rest/\(endpoint)"),
            resolvingAgainstBaseURL: false
        )

        var items = [
            URLQueryItem(name: "u", value: username),
            URLQueryItem(name: "t", value: token),
            URLQueryItem(name: "s", value: salt),
            URLQueryItem(name: "v", value: apiVersion),
            URLQueryItem(name: "c", value: clientName),
            URLQueryItem(name: "f", value: "json"),
        ]
        items.append(contentsOf: query.compactMap { key, value in
            value.map { URLQueryItem(name: key, value: $0) }
        })
        items.append(contentsOf: repeated)

        components?.queryItems = items
        return components?.url
    }
}

/// Talks to Navidrome over the Subsonic/OpenSubsonic API.
///
/// Everything the app knows about the library comes through here. Play counts,
/// ratings and playlists deliberately live on the server rather than in the app,
/// so the desktop client and this one stay in sync without either owning state.
actor SubsonicClient {
    struct Credentials: Codable, Equatable, Sendable {
        var baseURL: URL
        var username: String
        var password: String
    }

    enum ClientError: LocalizedError {
        case notConfigured
        case server(String)
        case transport(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "No server configured."
            case let .server(message): return message
            case let .transport(message): return message
            }
        }

        /// Transport failures mean "the server was unreachable", which is what
        /// offline detection keys on. A server *error* means we reached it fine.
        var isTransport: Bool {
            if case .transport = self { return true }
            return false
        }
    }

    private let session: URLSession
    private let decoder = JSONDecoder()
    private var credentials: Credentials?
    private(set) var capabilities: ServerCapabilities = .init()

    init() {
        let configuration = URLSessionConfiguration.default
        // The default 60s timeout is why offline apps feel broken: every tap hangs
        // for a minute before falling back. Offline detection is only as fast as
        // the failure, and this server is on the LAN.
        configuration.timeoutIntervalForRequest = 8
        #if canImport(Darwin)
        configuration.waitsForConnectivity = false
        #endif
        session = URLSession(configuration: configuration)
    }

    func configure(_ credentials: Credentials?) {
        self.credentials = credentials
        if credentials == nil { capabilities = .init() }
    }

    /// A synchronous, `Sendable` snapshot for building media URLs off-actor.
    func makeSigner() -> SubsonicSigner? {
        credentials.map(SubsonicSigner.init(credentials:))
    }

    // MARK: - Plumbing

    private func dataURL(
        _ endpoint: String,
        _ query: [String: String?] = [:],
        _ repeated: [URLQueryItem] = []
    ) throws -> URL {
        guard let credentials else { throw ClientError.notConfigured }

        let salt = SubsonicAuth.makeSalt()
        let url = SubsonicAuth.buildURL(
            baseURL: credentials.baseURL,
            endpoint: endpoint,
            username: credentials.username,
            token: SubsonicAuth.token(password: credentials.password, salt: salt),
            salt: salt,
            query: query,
            repeated: repeated
        )

        guard let url else { throw ClientError.notConfigured }
        return url
    }

    private func fetch(
        _ endpoint: String,
        _ query: [String: String?],
        _ repeated: [URLQueryItem] = []
    ) async throws -> Data {
        let url = try dataURL(endpoint, query, repeated)
        do {
            let (data, _) = try await session.data(from: url)
            return data
        } catch {
            // Recorded rather than only thrown: most callers use `try?` so the screen
            // can fall back to cache, which means the reason would otherwise vanish.
            await Diagnostics.shared.record(endpoint, error.localizedDescription)
            throw ClientError.transport(error.localizedDescription)
        }
    }

    /// Same parameters, moved into a form body.
    ///
    /// Needed because `savePlayQueue` for a 292-track playlist is ~7 KB of repeated
    /// `id=` parameters, and a URL that long is not something to rely on. The server
    /// advertises the `formPost` extension, which is exactly this.
    private func post(
        _ endpoint: String,
        _ query: [String: String?],
        _ repeated: [URLQueryItem] = []
    ) async throws -> Data {
        guard let credentials else { throw ClientError.notConfigured }

        let salt = SubsonicAuth.makeSalt()
        var items = [
            URLQueryItem(name: "u", value: credentials.username),
            URLQueryItem(name: "t", value: SubsonicAuth.token(
                password: credentials.password, salt: salt
            )),
            URLQueryItem(name: "s", value: salt),
            URLQueryItem(name: "v", value: SubsonicAuth.apiVersion),
            URLQueryItem(name: "c", value: SubsonicAuth.clientName),
            URLQueryItem(name: "f", value: "json"),
        ]
        items.append(contentsOf: query.compactMap { key, value in
            value.map { URLQueryItem(name: key, value: $0) }
        })
        items.append(contentsOf: repeated)

        var components = URLComponents()
        components.queryItems = items
        guard let body = components.percentEncodedQuery,
              let url = URL(string: credentials.baseURL.absoluteString)?
                  .appendingPathComponent("rest/\(endpoint)")
        else { throw ClientError.notConfigured }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)

        do {
            let (data, _) = try await session.data(for: request)
            return data
        } catch {
            await Diagnostics.shared.record(endpoint, error.localizedDescription)
            throw ClientError.transport(error.localizedDescription)
        }
    }

    private func get<T: Decodable & PayloadKeyed>(
        _ endpoint: String,
        query: [String: String?] = [:],
        repeated: [URLQueryItem] = [],
        as _: T.Type
    ) async throws -> T {
        let data = try await fetch(endpoint, query, repeated)

        let envelope: Envelope<T>
        do {
            envelope = try decoder.decode(Envelope<T>.self, from: data)
        } catch {
            throw ClientError.server("Unexpected response from server.")
        }

        if let error = envelope.subsonicResponse.error {
            throw ClientError.server(error.message)
        }
        guard let payload = envelope.subsonicResponse.payload else {
            throw ClientError.server("Server returned no data.")
        }
        return payload
    }

    /// For endpoints whose only meaningful answer is success or failure.
    private func perform(
        _ endpoint: String,
        query: [String: String?] = [:],
        repeated: [URLQueryItem] = []
    ) async throws {
        let data = try await fetch(endpoint, query, repeated)

        guard let decoded = try? decoder.decode(StatusOnly.self, from: data) else {
            throw ClientError.server("Unexpected response from server.")
        }
        if let error = decoded.subsonicResponse.error {
            throw ClientError.server(error.message)
        }
        guard decoded.subsonicResponse.status == "ok" else {
            throw ClientError.server("Server rejected the request.")
        }
    }

    // MARK: - Session

    func ping() async throws {
        try await perform("ping.view")
    }

    /// Cached at sign-in so features can gate on advertised extensions instead of
    /// trying an endpoint and interpreting the failure.
    func loadCapabilities() async {
        struct Payload: Decodable, PayloadKeyed {
            let openSubsonicExtensions: [Extension]?
            static var payloadKey: String { "openSubsonicExtensions" }

            struct Extension: Decodable {
                let name: String
                let versions: [Int]?
            }
        }

        // The payload is an array directly under the key, so decode by hand.
        guard let data = try? await fetch("getOpenSubsonicExtensions.view", [:]),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = raw["subsonic-response"] as? [String: Any],
              let list = response["openSubsonicExtensions"] as? [[String: Any]]
        else { return }

        var names: Set<String> = []
        var lyricsVersions: [Int] = []
        for entry in list {
            guard let name = entry["name"] as? String else { continue }
            names.insert(name)
            if name == "songLyrics" {
                lyricsVersions = entry["versions"] as? [Int] ?? []
            }
        }

        capabilities = ServerCapabilities(
            extensions: names,
            songLyricsVersions: lyricsVersions
        )
    }

    func musicFolders() async throws -> [MusicFolder] {
        try await get("getMusicFolders.view", as: MusicFolders.self).musicFolder ?? []
    }

    // MARK: - Browse

    func albums(
        type: AlbumSort = .newest,
        size: Int = 100,
        offset: Int = 0,
        scope: LibraryScope = .all,
        genre: String? = nil
    ) async throws -> [Album] {
        try await get(
            "getAlbumList2.view",
            query: [
                "genre": genre,
                "musicFolderId": scope.queryValue,
                "offset": String(offset),
                "size": String(size),
                "type": genre == nil ? type.rawValue : "byGenre",
            ],
            as: AlbumList2.self
        ).album ?? []
    }

    /// Albums released in a span of years, for decade browsing.
    ///
    /// Two things about the server's answer. It filters on the **release** year while the
    /// `year` each row carries is the *original* year, so a 1979 record reissued in 1995
    /// comes back under the 1990s with "1979" printed on it — verified. Don't re-filter
    /// these rows client-side on `year` or legitimate ones vanish. And the only order
    /// control is the direction of the span: `from < to` gives oldest first, reversed
    /// gives newest first.
    func albums(
        fromYear: Int,
        toYear: Int,
        size: Int = 100,
        offset: Int = 0,
        scope: LibraryScope = .all
    ) async throws -> [Album] {
        try await get(
            "getAlbumList2.view",
            query: [
                "fromYear": String(fromYear),
                "musicFolderId": scope.queryValue,
                "offset": String(offset),
                "size": String(size),
                "toYear": String(toYear),
                "type": "byYear",
            ],
            as: AlbumList2.self
        ).album ?? []
    }

    func albumDetail(id: String) async throws -> AlbumDetail {
        try await get("getAlbum.view", query: ["id": id], as: AlbumDetail.self)
    }

    func artists(scope: LibraryScope = .all) async throws -> [ArtistIndex] {
        try await get(
            "getArtists.view",
            query: ["musicFolderId": scope.queryValue],
            as: ArtistsRoot.self
        ).index ?? []
    }

    /// The top-level folders, for browsing by folder the way Plexamp's Folders does.
    func folderIndexes(scope: LibraryScope = .all) async throws -> [ArtistIndex] {
        try await get(
            "getIndexes.view",
            query: ["musicFolderId": scope.queryValue],
            as: FolderIndexes.self
        ).index ?? []
    }

    func musicDirectory(id: String) async throws -> MusicDirectory {
        try await get("getMusicDirectory.view", query: ["id": id], as: MusicDirectory.self)
    }

    func artistDetail(id: String) async throws -> ArtistDetail {
        try await get("getArtist.view", query: ["id": id], as: ArtistDetail.self)
    }

    /// Every track by an artist, in release order.
    ///
    /// Subsonic has no "all songs by artist" call, and `getTopSongs` is not it: that is
    /// Last.fm's global chart matched to local files by title, which on this server finds one
    /// Nirvana track out of 67. So this is `getArtist` plus one `getAlbum` per album, fetched
    /// concurrently and reassembled in album order, because a discography that arrives in
    /// whichever order the requests answered is not a discography.
    func artistSongs(id: String) async throws -> [Song] {
        let detail = try await artistDetail(id: id)
        let ordered = detail.albums.sorted { ($0.year ?? 0) < ($1.year ?? 0) }
        guard !ordered.isEmpty else { return [] }

        var byAlbum: [String: [Song]] = [:]
        await withTaskGroup(of: (String, [Song]).self) { group in
            for album in ordered {
                group.addTask { [weak self] in
                    guard let self else { return (album.id, []) }
                    return (album.id, (try? await albumDetail(id: album.id))?.songs ?? [])
                }
            }
            for await (albumID, songs) in group {
                byAlbum[albumID] = songs
            }
        }

        return ordered.flatMap { byAlbum[$0.id] ?? [] }
    }

    /// One song by id, for the cases where an id is all there is.
    func song(id: String) async throws -> Song {
        try await get("getSong.view", query: ["id": id], as: FetchedSong.self).song
    }

    func topSongs(artist: String, count: Int = 5) async throws -> [Song] {
        try await get(
            "getTopSongs.view",
            query: ["artist": artist, "count": String(count)],
            as: TopSongs.self
        ).song ?? []
    }

    /// Playlists are not folder-scoped by the server, so this takes no scope.
    func playlists() async throws -> [Playlist] {
        try await get("getPlaylists.view", as: Playlists.self).playlist ?? []
    }

    func playlistDetail(id: String) async throws -> PlaylistDetail {
        try await get("getPlaylist.view", query: ["id": id], as: PlaylistDetail.self)
    }

    func genres(scope: LibraryScope = .all) async throws -> [Genre] {
        try await get(
            "getGenres.view",
            query: ["musicFolderId": scope.queryValue],
            as: Genres.self
        ).genre ?? []
    }

    func songsByGenre(
        _ genre: String,
        count: Int = 100,
        offset: Int = 0,
        scope: LibraryScope = .all
    ) async throws -> [Song] {
        try await get(
            "getSongsByGenre.view",
            query: [
                "count": String(count),
                "genre": genre,
                "musicFolderId": scope.queryValue,
                "offset": String(offset),
            ],
            as: SongsByGenre.self
        ).song ?? []
    }

    func starred(scope: LibraryScope = .all) async throws -> Starred2 {
        try await get(
            "getStarred2.view",
            query: ["musicFolderId": scope.queryValue],
            as: Starred2.self
        )
    }

    /// `fromYear`/`toYear` filter on the song's year, both inclusive, and either may be
    /// given alone. The span is what an era DJ and a decade station draw from.
    func randomSongs(
        size: Int = 50,
        genre: String? = nil,
        fromYear: Int? = nil,
        toYear: Int? = nil,
        scope: LibraryScope = .all
    ) async throws -> [Song] {
        try await get(
            "getRandomSongs.view",
            query: [
                "fromYear": fromYear.map(String.init),
                "genre": genre,
                "musicFolderId": scope.queryValue,
                "size": String(size),
                "toYear": toYear.map(String.init),
            ],
            as: RandomSongs.self
        ).song ?? []
    }

    /// Biography and similar artists, from whichever agents the server has configured.
    /// Empty rather than failing on a server without them, which the caller should treat
    /// as "nothing to show", not as an error.
    func artistInfo(id: String, similarCount: Int = 20) async throws -> ArtistInfo {
        try await get(
            "getArtistInfo2.view",
            query: ["count": String(similarCount), "id": id],
            as: ArtistInfo.self
        )
    }

    func albumInfo(id: String) async throws -> AlbumInfo {
        try await get("getAlbumInfo2.view", query: ["id": id], as: AlbumInfo.self)
    }

    func search(
        query: String,
        artistCount: Int = 8,
        albumCount: Int = 12,
        songCount: Int = 30,
        artistOffset: Int = 0,
        albumOffset: Int = 0,
        songOffset: Int = 0,
        scope: LibraryScope = .all
    ) async throws -> SearchResult3 {
        try await get(
            "search3.view",
            query: [
                "albumCount": String(albumCount),
                "albumOffset": String(albumOffset),
                "artistCount": String(artistCount),
                "artistOffset": String(artistOffset),
                "musicFolderId": scope.queryValue,
                "query": query,
                "songCount": String(songCount),
                "songOffset": String(songOffset),
            ],
            as: SearchResult3.self
        )
    }

    func lyrics(songID: String) async throws -> [StructuredLyrics] {
        try await get(
            "getLyricsBySongId.view",
            query: ["id": songID],
            as: LyricsList.self
        ).structuredLyrics ?? []
    }

    // MARK: - Writes (the server stays the source of truth)

    func star(id: String, kind: StarKind = .song) async throws {
        try await perform("star.view", query: [kind.parameter: id])
    }

    func unstar(id: String, kind: StarKind = .song) async throws {
        try await perform("unstar.view", query: [kind.parameter: id])
    }

    func setRating(id: String, rating: Int) async throws {
        try await perform("setRating.view", query: ["id": id, "rating": String(rating)])
    }

    /// `time` is epoch milliseconds of the *listen*, not of the request, so a
    /// scrobble flushed from the outbox days later is still recorded correctly.
    func scrobble(id: String, submission: Bool, at listenedAt: Date? = nil) async throws {
        try await perform(
            "scrobble.view",
            query: [
                "id": id,
                "submission": submission ? "true" : "false",
                "time": listenedAt.map { String(Int($0.timeIntervalSince1970 * 1000)) },
            ]
        )
    }

    // MARK: - Playlists (read-write)

    /// Returns the created playlist, so the caller can navigate straight to it.
    ///
    /// Note the two-step: Subsonic's `createPlaylist` accepts songs, but Navidrome
    /// does not return the entries in that response, and a name is not unique enough
    /// to look the playlist up again afterwards. Verified against the live server:
    /// the response carries the new id, which is enough.
    func createPlaylist(name: String, songIDs: [String] = []) async throws -> Playlist {
        try await get(
            "createPlaylist.view",
            query: ["name": name],
            repeated: songIDs.map { URLQueryItem(name: "songId", value: $0) },
            as: CreatedPlaylist.self
        ).playlist
    }

    /// Appends. `songIdToAdd` always adds to the end -- there is no insert-at-index in
    /// the API.
    func addToPlaylist(id: String, songIDs: [String]) async throws {
        guard !songIDs.isEmpty else { return }
        try await perform(
            "updatePlaylist.view",
            query: ["playlistId": id],
            repeated: songIDs.map { URLQueryItem(name: "songIdToAdd", value: $0) }
        )
    }

    /// Indices are positions in the playlist as the server currently has it, so they
    /// are only valid against a freshly fetched copy.
    func removeFromPlaylist(id: String, indices: [Int]) async throws {
        guard !indices.isEmpty else { return }
        try await perform(
            "updatePlaylist.view",
            query: ["playlistId": id],
            repeated: indices.map {
                URLQueryItem(name: "songIndexToRemove", value: String($0))
            }
        )
    }

    func renamePlaylist(id: String, name: String, comment: String? = nil) async throws {
        try await perform(
            "updatePlaylist.view",
            query: ["playlistId": id, "name": name, "comment": comment]
        )
    }

    func deletePlaylist(id: String) async throws {
        try await perform("deletePlaylist.view", query: ["id": id])
    }

    // MARK: - Radio

    /// Navidrome computes this itself -- no Last.fm key needed, unlike `getTopSongs`.
    /// Verified: a **song** id returns results, an **artist** id returns none, so this
    /// is seeded from a track rather than from an artist.
    func similarSongs(toSongID id: String, count: Int = 50) async throws -> [Song] {
        try await get(
            "getSimilarSongs2.view",
            query: ["count": String(count), "id": id],
            as: SimilarSongs.self
        ).song ?? []
    }

    // MARK: - Play queue (cross-device)

    /// The queue as last saved by any of this user's clients.
    ///
    /// This is what makes the phone and desktop Feishin two views of one session rather
    /// than two players that merely share a library.
    func savedQueue() async throws -> SavedQueue {
        try await get("getPlayQueue.view", as: SavedQueue.self)
    }

    /// `position` is milliseconds into the current track, which is the unit Subsonic
    /// uses here even though `scrobble` uses seconds.
    func saveQueue(songIDs: [String], currentID: String?, positionMilliseconds: Int) async throws {
        guard !songIDs.isEmpty else { return }

        let data = try await post(
            "savePlayQueue.view",
            [
                "current": currentID,
                "position": String(max(0, positionMilliseconds)),
            ],
            songIDs.map { URLQueryItem(name: "id", value: $0) }
        )

        guard let decoded = try? decoder.decode(StatusOnly.self, from: data) else {
            throw ClientError.server("Unexpected response from server.")
        }
        if let error = decoded.subsonicResponse.error {
            throw ClientError.server(error.message)
        }
    }

    // MARK: - Resume positions

    /// Bookmarks are per track, unlike `savedQueue`. Verified end to end against this
    /// server: create, list and delete all work, and the list came back empty to start
    /// with, so nothing else on this account is using them.
    func bookmarks() async throws -> [Bookmark] {
        try await get("getBookmarks.view", as: BookmarkList.self).bookmark ?? []
    }

    func createBookmark(
        id: String,
        positionMilliseconds: Int,
        comment: String? = nil
    ) async throws {
        try await perform(
            "createBookmark.view",
            query: [
                "comment": comment,
                "id": id,
                "position": String(max(0, positionMilliseconds)),
            ]
        )
    }

    func deleteBookmark(id: String) async throws {
        try await perform("deleteBookmark.view", query: ["id": id])
    }

    // MARK: - Now playing elsewhere

    /// What every client on this account is playing. Used to show that desktop Feishin
    /// is running, which is otherwise invisible from the phone.
    func nowPlaying() async throws -> [NowPlayingEntry] {
        try await get("getNowPlaying.view", as: NowPlayingList.self).entry ?? []
    }

    // MARK: - Library scan

    func scanStatus() async throws -> ScanStatus {
        try await get("getScanStatus.view", as: ScanStatus.self)
    }

    /// Returns the status the server reports immediately, which is usually
    /// `scanning: true`.
    @discardableResult
    func startScan() async throws -> ScanStatus {
        try await get("startScan.view", as: ScanStatus.self)
    }

    enum StarKind: Sendable {
        case song, album, artist

        /// Stable name for persistence. Distinct from `parameter`, which is the query
        /// key the API wants -- those must not be conflated, because renaming one to
        /// suit the other would silently break stored outbox entries.
        var parameterName: String {
            switch self {
            case .song: return "song"
            case .album: return "album"
            case .artist: return "artist"
            }
        }

        var parameter: String {
            switch self {
            case .song: return "id"
            case .album: return "albumId"
            case .artist: return "artistId"
            }
        }
    }
}

struct ServerCapabilities: Sendable {
    var extensions: Set<String> = []
    var songLyricsVersions: [Int] = []

    var supportsLyrics: Bool { extensions.contains("songLyrics") }
    var supportsPlaybackReport: Bool { extensions.contains("playbackReport") }
    var supportsTranscoding: Bool { extensions.contains("transcoding") }
}

// MARK: - Response shapes

/// Subsonic wraps everything in `subsonic-response` and names the payload
/// differently per endpoint, so each response type declares its own key.
private struct Envelope<T: Decodable & PayloadKeyed>: Decodable {
    let subsonicResponse: Response<T>

    enum CodingKeys: String, CodingKey {
        case subsonicResponse = "subsonic-response"
    }
}

private struct Response<T: Decodable & PayloadKeyed>: Decodable {
    let error: SubsonicError?
    let payload: T?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyKey.self)
        error = try container.decodeIfPresent(SubsonicError.self, forKey: AnyKey("error"))
        payload = try container.decodeIfPresent(T.self, forKey: AnyKey(T.payloadKey))
    }
}

private struct StatusOnly: Decodable {
    struct Inner: Decodable {
        let status: String?
        let error: SubsonicError?
    }

    let subsonicResponse: Inner

    enum CodingKeys: String, CodingKey {
        case subsonicResponse = "subsonic-response"
    }
}

private struct SubsonicError: Decodable {
    let code: Int
    let message: String
}

private struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }

    init(_ stringValue: String) { self.stringValue = stringValue }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue _: Int) { nil }
}

/// Lets a payload type declare which key it lives under in the envelope.
