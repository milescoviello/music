import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Music videos, from the sonic service (`server/sonic/sonic/video.py`): a song's official
/// video found on YouTube, the pick made by hand that replaces it, and the addresses a
/// player opens.
///
/// Those addresses are the service's, not YouTube's. It writes the HLS playlists itself
/// from YouTube's own streams and relays their bytes, so a video plays in the system
/// player with no ads, and from a phone away from home (YouTube's stream addresses only
/// work from the address that asked for them).
struct VideoClient: Sendable {
    struct Video: Codable, Hashable, Sendable, Identifiable {
        var id: String
        var title: String
        var channel: String
        var duration: Double?
        var verified: Bool?
        var views: Int?
        /// The service's reading of what the video is of -- "Artist - Song (Official
        /// Video)" -- for asking the library to get it.
        var artist: String?
        var song: String?

        init(id: String, title: String, channel: String, duration: Double? = nil, verified: Bool? = nil,
             views: Int? = nil, artist: String? = nil, song: String? = nil) {
            self.id = id
            self.title = title
            self.channel = channel
            self.duration = duration
            self.verified = verified
            self.views = views
            self.artist = artist
            self.song = song
        }
    }

    /// A song's video: chosen by hand (`manual`), found by the service, or none (`video`
    /// nil). `offset` is how far into the video the song's first second is.
    struct Match: Codable, Equatable, Sendable {
        var video: Video?
        var manual: Bool
        var offset: Double
    }

    /// What the desktop opens: the tallest video stream and the best audio, as paths on
    /// the service.
    struct Streams: Decodable, Equatable, Sendable {
        var id: String
        var title: String
        var channel: String
        var duration: Double
        var width: Int
        var height: Int
        var video: String
        var audio: String
        var audioCodec: String
    }

    private struct Items: Decodable {
        let items: [Video]
    }

    private struct Choice: Encodable {
        var artist: String
        var title: String
        var video: Video
    }

    var configuration: SonicClient.Configuration
    var session: URLSession = .shared

    // MARK: - Calls

    /// YouTube's results for a search, best first.
    func search(_ query: String, limit: Int = 12) async throws -> [Video] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let data = try await send("GET", "v1/video/search", ["q": trimmed, "limit": String(limit)], timeout: 20)
        return try JSONDecoder().decode(Items.self, from: data).items
    }

    /// The song's video, found the first time it is asked for. `warm` has the service open
    /// the video's streams ahead, so the switch to it is immediate.
    func match(artist: String, title: String, duration: Double?, warm: Bool = false) async throws -> Match {
        var query = ["artist": artist, "title": title]
        if let duration, duration > 0 { query["duration"] = String(Int(duration.rounded())) }
        if warm { query["warm"] = "1" }
        let data = try await send("GET", "v1/video/match", query, timeout: 30)
        return try JSONDecoder().decode(Match.self, from: data)
    }

    /// The video this song gets from now on.
    func choose(_ video: Video, artist: String, title: String) async throws -> Match {
        let body = try JSONEncoder().encode(Choice(artist: artist, title: title, video: video))
        let data = try await send("PUT", "v1/video/match", [:], body: body, timeout: 15)
        return try JSONDecoder().decode(Match.self, from: data)
    }

    /// Back to the automatic pick.
    func useAutomatic(artist: String, title: String) async throws {
        _ = try await send("DELETE", "v1/video/match", ["artist": artist, "title": title], timeout: 15)
    }

    func streams(videoID: String, quality: VideoQuality = .auto) async throws -> Streams {
        let height = quality.maxHeight.map { ["height": String($0)] } ?? [:]
        let data = try await send("GET", "v1/video/\(videoID)/streams", height, timeout: 30)
        return try JSONDecoder().decode(Streams.self, from: data)
    }

    // MARK: - Addresses

    /// What AVPlayer opens: every height, adaptive, with the audio -- or, for a chosen
    /// quality, the one height.
    func masterURL(videoID: String, quality: VideoQuality = .auto) -> URL? {
        mediaURL("v1/video/\(videoID)/master.m3u8", extra: quality.maxHeight.map { [URLQueryItem(name: "height", value: String($0))] } ?? [])
    }

    func thumbnailURL(videoID: String) -> URL? {
        mediaURL("v1/video/\(videoID)/thumb")
    }

    /// A path the service named (`Streams.video`), as an address. The token, when there is
    /// one, rides on the address: a player fetching it cannot add our header.
    func mediaURL(_ path: String, extra: [URLQueryItem] = []) -> URL? {
        let bare = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        guard var components = URLComponents(
            url: configuration.baseURL.appendingPathComponent(bare),
            resolvingAgainstBaseURL: false
        ) else { return nil }
        var items = extra
        if let token = configuration.token, !token.isEmpty {
            items.append(URLQueryItem(name: "token", value: token))
        }
        components.queryItems = items.isEmpty ? nil : items
        return components.url
    }

    /// The video id in a YouTube link someone pasted, or nil. Takes watch, share, Shorts,
    /// embed and YouTube Music links, and a bare id.
    static func videoID(fromLink text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isVideoID(trimmed) { return trimmed }
        guard let components = URLComponents(string: trimmed.contains("://") ? trimmed : "https://" + trimmed),
              let host = components.host?.lowercased()
        else { return nil }
        if host.hasSuffix("youtu.be") {
            let id = components.path.split(separator: "/").first.map(String.init) ?? ""
            return isVideoID(id) ? id : nil
        }
        guard host.hasSuffix("youtube.com") || host.hasSuffix("youtube-nocookie.com") else { return nil }
        if let id = components.queryItems?.first(where: { $0.name == "v" })?.value, isVideoID(id) {
            return id
        }
        let parts = components.path.split(separator: "/").map(String.init)
        if parts.count >= 2, ["shorts", "embed", "live", "v"].contains(parts[0]), isVideoID(parts[1]) {
            return parts[1]
        }
        return nil
    }

    static func isVideoID(_ text: String) -> Bool {
        text.count == 11 && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    // MARK: - Plumbing

    func url(_ path: String, _ query: [String: String] = [:]) -> URL? {
        SonicClient(configuration: configuration).url(path, query)
    }

    private func send(
        _ method: String,
        _ path: String,
        _ query: [String: String],
        body: Data? = nil,
        timeout: TimeInterval
    ) async throws -> Data {
        guard let url = url(path, query) else { throw SonicError.badURL }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let token = configuration.token, !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "X-Sonic-Token")
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { throw SonicError.notFound }
        guard (200...299).contains(status) else { throw SonicError.status(status) }
        return data
    }
}

extension VideoClient.Video {
    /// "3:41"
    var durationText: String? {
        guard let duration, duration > 0 else { return nil }
        let seconds = Int(duration.rounded())
        return seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// "Channel · 3:41"
    var subtitle: String {
        [channel.isEmpty ? nil : channel, durationText].compactMap { $0 }.joined(separator: " · ")
    }
}

/// How tall music videos play, from the Streaming settings. Auto is every height up to
/// 1080p, which the player picks among by the connection; a height is that one, or the
/// nearest under it the video has, and stays there.
enum VideoQuality: Int, CaseIterable, Identifiable, Sendable {
    case auto = 0
    case p1080 = 1080
    case p720 = 720
    case p480 = 480
    case p360 = 360

    var id: Int { rawValue }
    var label: String { self == .auto ? "Auto" : "\(rawValue)p" }
    var maxHeight: Int? { self == .auto ? nil : rawValue }
}
