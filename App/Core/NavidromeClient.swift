import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Navidrome's own API, used for the one thing Subsonic cannot answer: **when**.
///
/// Subsonic exposes a `playCount` and no dates for songs — `getAlbumList2?type=recent`
/// sorts *albums* by last play and that is the whole of it. Navidrome's native API sorts
/// songs by `playDate` and returns it, which is what makes a real "recently played" list
/// and an all-time top-tracks list possible, covering **every** device and every play
/// including the ones imported from Plex.
///
/// Worth being precise about what is and is not here: Navidrome does keep a per-play
/// event log — a `scrobbles` table with a timestamp per play — but **neither API exposes
/// it**. So per-play analysis (time of day, streaks) still has to come from the app's own
/// history, while totals and last-played come from here and reach back through the whole
/// library.
///
/// A second auth scheme, unavoidably: this endpoint wants a JWT, not the salted-MD5 that
/// every Subsonic call uses.
actor NavidromeClient {
    struct Song: Decodable, Sendable, Identifiable {
        let id: String
        let title: String
        var album: String?
        var albumId: String?
        var artist: String?
        var artistId: String?
        var albumArtistId: String?
        var playCount: Int?
        var playDate: Date?
        var starred: Bool?
        var rating: Int?
        var duration: Double?
    }

    /// One window onto a native-API collection, and how many rows exist behind it.
    struct Page<Element: Sendable>: Sendable {
        var items: [Element]
        /// From `X-Total-Count`, which the native API sends on every list response.
        /// Subsonic sends nothing of the kind — there the only way to learn a count is to
        /// page until it runs dry — so anything that wants to say "42 of 2,227", or to
        /// walk a collection a chunk at a time and know when to stop, comes through here.
        var total: Int
    }

    /// The window to ask for when walking a whole collection. The server honours whatever
    /// `_end` it is given — verified at 6,000 rows in a single response, with no cap and
    /// no `Content-Range` — so this is picked to keep one response to a few megabytes,
    /// not to satisfy a limit.
    static let pageSize = 1_000

    private var credentials: SubsonicClient.Credentials?
    private var token: String?
    private let session: URLSession
    private let decoder: JSONDecoder

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 10
        session = URLSession(configuration: configuration)

        decoder = JSONDecoder()
        // Navidrome returns RFC3339 with nanosecond precision, which the standard
        // strategies reject.
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = ServerDate.parse(text) else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unrecognised date: \(text)"
                ))
            }
            return date
        }
    }

    func configure(_ credentials: SubsonicClient.Credentials?) {
        self.credentials = credentials
        token = nil
    }

    /// Songs, sorted and filtered by the native API's own query language.
    ///
    /// `filters` goes straight through as query items: `["starred": "true"]`,
    /// `["album_id": id]`. That is the whole reason this client exists — Subsonic can
    /// neither sort songs by play date nor filter to favourites-and-sort-by-something.
    func songs(
        matching filters: [String: String] = [:],
        sortedBy field: String,
        ascending: Bool = false,
        start: Int = 0,
        limit: Int = 25
    ) async throws -> Page<Song> {
        var query = filters
        query["_sort"] = field
        query["_order"] = ascending ? "ASC" : "DESC"
        query["_start"] = String(start)
        query["_end"] = String(start + limit)

        let (items, response): ([Song], HTTPURLResponse) = try await request(
            path: "api/song", query: query
        )
        return Page(items: items, total: Self.total(from: response) ?? items.count)
    }

    /// Starred tracks, least recently played first — "you loved this and have not heard it
    /// in a year", which is not answerable any other way: `getStarred2` returns favourites
    /// in no useful order and carries no play date at all.
    ///
    /// Verified against this server: `starred=true` combines with the `playDate` sort, and
    /// an ascending sort puts **never-played tracks first** — a nil date sorts before any
    /// date. That is the right order here: a favourite you have never actually played is
    /// the most forgotten thing there is.
    func forgottenFavourites(limit: Int = 50) async throws -> [Song] {
        try await songs(
            matching: ["starred": "true"],
            sortedBy: "playDate",
            ascending: true,
            limit: limit
        ).items
    }

    /// Only tracks that have actually been played; the API happily returns never-played
    /// ones otherwise, which makes a "recently played" list mostly noise.
    func recentlyPlayed(limit: Int = 25) async throws -> [Song] {
        try await songs(sortedBy: "playDate", limit: limit).items
            .filter { $0.playDate != nil && ($0.playCount ?? 0) > 0 }
    }

    func mostPlayed(limit: Int = 25) async throws -> [Song] {
        try await songs(sortedBy: "playCount", limit: limit).items
            .filter { ($0.playCount ?? 0) > 0 }
    }

    // MARK: - Playlist order

    /// Moves a track within a playlist.
    ///
    /// Subsonic cannot do this at all: `updatePlaylist` only appends
    /// (`songIdToAdd`) and removes by index, so the only way to reorder there is to
    /// empty the playlist and re-add it — and if the second call fails the playlist is
    /// gone. Navidrome's own API has a real move, which is why this is worth a second
    /// client.
    ///
    /// Positions are 1-based and are renumbered by the server after every move, so the
    /// caller must re-read rather than assume. `insertBefore` is the position of the track
    /// this one should land in front of; one past the end appends. Both are sent as
    /// **strings** — the endpoint rejects a JSON number outright, which is the kind of
    /// thing only a probe finds. Verified on a throwaway playlist, moves up, down and to
    /// the end.
    func movePlaylistTrack(
        playlistID: String,
        from position: Int,
        insertBefore target: Int
    ) async throws {
        guard let credentials else { throw SubsonicClient.ClientError.notConfigured }

        for attempt in 0..<2 {
            let bearer: String
            if let existing = token {
                bearer = existing
            } else {
                bearer = try await login()
            }

            let url = credentials.baseURL
                .appendingPathComponent("api/playlist/\(playlistID)/tracks/\(position)")

            var request = URLRequest(url: url)
            request.httpMethod = "PUT"
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "x-nd-authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(
                withJSONObject: ["insert_before": String(target)]
            )

            let (_, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0

            if status == 401, attempt == 0 {
                token = nil
                continue
            }
            guard (200...299).contains(status) else {
                throw SubsonicClient.ClientError.server("Navidrome replied \(status).")
            }
            return
        }

        throw SubsonicClient.ClientError.server("Navidrome would not authenticate.")
    }

    // MARK: - Plumbing

    private func login() async throws -> String {
        guard let credentials else { throw SubsonicClient.ClientError.notConfigured }

        var request = URLRequest(
            url: credentials.baseURL.appendingPathComponent("auth/login")
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "username": credentials.username,
            "password": credentials.password,
        ])

        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = object["token"] as? String
        else {
            throw SubsonicClient.ClientError.server("Navidrome rejected the login.")
        }

        self.token = token
        return token
    }

    private static func total(from response: HTTPURLResponse) -> Int? {
        response.value(forHTTPHeaderField: "X-Total-Count").flatMap(Int.init)
    }

    private func request<T: Decodable>(path: String, query: [String: String]) async throws -> T {
        let (decoded, _): (T, HTTPURLResponse) = try await request(path: path, query: query)
        return decoded
    }

    private func request<T: Decodable>(
        path: String,
        query: [String: String]
    ) async throws -> (T, HTTPURLResponse) {
        guard let credentials else { throw SubsonicClient.ClientError.notConfigured }

        // One retry after a fresh login: the JWT expires, and the only way to find out is
        // to be told 401.
        for attempt in 0..<2 {
            // `token ?? login()` reads as an autoclosure, which cannot be async.
            let bearer: String
            if let existing = token {
                bearer = existing
            } else {
                bearer = try await login()
            }

            var components = URLComponents(
                url: credentials.baseURL.appendingPathComponent(path),
                resolvingAgainstBaseURL: false
            )
            components?.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
            guard let url = components?.url else {
                throw SubsonicClient.ClientError.notConfigured
            }

            var request = URLRequest(url: url)
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "x-nd-authorization")

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw SubsonicClient.ClientError.transport("No response from Navidrome.")
            }

            if http.statusCode == 401, attempt == 0 {
                token = nil
                continue
            }

            guard http.statusCode == 200 else {
                throw SubsonicClient.ClientError.server("Navidrome replied \(http.statusCode).")
            }

            // Every response carries a freshly issued JWT. Adopting it means a long-lived
            // session slides forward instead of hitting the 401 path days later.
            if let refreshed = http.value(forHTTPHeaderField: "x-nd-authorization"),
               !refreshed.isEmpty {
                token = refreshed
            }

            return (try decoder.decode(T.self, from: data), http)
        }

        throw SubsonicClient.ClientError.server("Navidrome would not authenticate.")
    }
}
