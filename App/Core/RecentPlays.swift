import Foundation

/// What a queue was started from: Plexamp's Recent Plays are these, not tracks — the
/// album you put on, the playlist, the station — so the shelf is a way back to them.
enum PlayOrigin: Codable, Hashable, Sendable, Identifiable {
    case album(id: String, name: String, artist: String?, coverArt: String?)
    case playlist(id: String, name: String, coverArt: String?)
    case artist(id: String, name: String, coverArt: String?)
    case station(Station, coverArt: String?)

    var id: String {
        switch self {
        case let .album(id, _, _, _): return "album-\(id)"
        case let .playlist(id, _, _): return "playlist-\(id)"
        case let .artist(id, _, _): return "artist-\(id)"
        case let .station(station, _): return "station-\(station.id)"
        }
    }

    var title: String {
        switch self {
        case let .album(_, name, _, _), let .playlist(_, name, _), let .artist(_, name, _): return name
        case let .station(station, _): return station.title
        }
    }

    var subtitle: String {
        switch self {
        case let .album(_, _, artist, _): return artist ?? "Album"
        case .playlist: return "Playlist"
        case .artist: return "Artist"
        case .station: return "Station"
        }
    }

    var coverArt: String? {
        switch self {
        case let .album(_, _, _, cover), let .playlist(_, _, cover), let .artist(_, _, cover), let .station(_, cover):
            return cover
        }
    }

    /// Works out what a queue came from, from the queue itself, so no screen has to say:
    /// a station says so; a queue that is one album, played under that album's name, is
    /// the album; one named for a playlist the library has is that playlist; one that is
    /// all one artist, under the artist's name, is the artist. Anything else — a search
    /// result, a hand-built queue — is not something to go back to, and is nil.
    static func infer(songs: [Song], source: String, station: Station?, playlists: [Playlist]) -> PlayOrigin? {
        guard let first = songs.first else { return nil }

        if let station {
            return .station(station, coverArt: first.coverArt)
        }

        if let albumID = first.albumId, songs.allSatisfy({ $0.albumId == albumID }), source == first.album {
            return .album(id: albumID, name: source, artist: first.albumArtists?.first?.name ?? first.artist, coverArt: first.coverArt)
        }

        if let playlist = playlists.first(where: { $0.name == source }) {
            return .playlist(id: playlist.id, name: playlist.name, coverArt: playlist.coverArt ?? first.coverArt)
        }

        if let artistID = first.primaryArtistID, songs.allSatisfy({ $0.primaryArtistID == artistID }),
           source == (first.albumArtists?.first?.name ?? first.artist) {
            return .artist(id: artistID, name: source, coverArt: first.coverArt)
        }

        return nil
    }
}

/// The last things started, most recent first, each once.
struct RecentPlays: Codable, Equatable, Sendable {
    static let limit = 20

    private(set) var origins: [PlayOrigin] = []

    mutating func record(_ origin: PlayOrigin) {
        origins.removeAll { $0.id == origin.id }
        origins.insert(origin, at: 0)
        if origins.count > Self.limit { origins.removeLast(origins.count - Self.limit) }
    }
}
