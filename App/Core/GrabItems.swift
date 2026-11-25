import Foundation

/// Something to get into the library: a song or an album it does not have, or a song it has
/// whose file is lossy, to be put right in place.
enum AddMusicItem: Identifiable, Equatable {
    case song(artist: String, title: String, album: String? = nil, albumID: String? = nil,
              seconds: Int? = nil, videoID: String? = nil, cover: URL? = nil)
    case album(artist: String, title: String, year: String? = nil, albumID: String? = nil, cover: URL? = nil)
    /// The full album a song in the library came from, when the library has it on its own
    /// (`Song.isOnItsOwn`): the server looks the album up from the song.
    case fullAlbum(Song)
    case lossless(Song)

    var id: String {
        switch self {
        case let .song(artist, title, _, _, _, _, _): "song\u{1F}\(artist)\u{1F}\(title)"
        case let .album(artist, title, _, _, _): "album\u{1F}\(artist)\u{1F}\(title)"
        case let .fullAlbum(song): "full\u{1F}\(song.id)"
        case let .lossless(song): "lossless\u{1F}\(song.id)"
        }
    }

    var title: String {
        switch self {
        case let .song(_, title, _, _, _, _, _), let .album(_, title, _, _, _): title
        case let .fullAlbum(song): song.album ?? song.title
        case let .lossless(song): song.title
        }
    }

    var artist: String {
        switch self {
        case let .song(artist, _, _, _, _, _, _), let .album(artist, _, _, _, _): artist
        case let .fullAlbum(song), let .lossless(song): song.artist ?? ""
        }
    }

    var cover: URL? {
        switch self {
        case let .song(_, _, _, _, _, _, cover), let .album(_, _, _, _, cover): cover
        case .fullAlbum, .lossless: nil
        }
    }

    var coverArt: String? {
        switch self {
        case let .fullAlbum(song), let .lossless(song): song.coverArt
        case .song, .album: nil
        }
    }

    var isAlbum: Bool {
        switch self {
        case .album, .fullAlbum: true
        case .song, .lossless: false
        }
    }

    /// A song in the library is put right in its own library; anything new asks which.
    var asksForLibrary: Bool {
        if case .lossless = self { return false }
        return true
    }

    /// The request, as far as the item says; the sheet adds the library and the rest.
    func ask(library: SonicClient.Library, choose: Bool, albumToo: Bool) -> SonicClient.GrabAsk {
        switch self {
        case let .song(artist, title, album, albumID, seconds, videoID, _):
            SonicClient.GrabAsk(kind: .song, artist: artist, title: title, library: library, choose: choose,
                                album: album, albumId: albumID, albumToo: albumToo, length: seconds, videoId: videoID)
        case let .album(artist, title, year, albumID, _):
            SonicClient.GrabAsk(kind: .album, artist: artist, title: title, library: library, choose: choose,
                                albumId: albumID, year: year)
        case let .fullAlbum(song):
            // The song is had already, so only its album is got.
            SonicClient.GrabAsk(kind: .song, artist: song.artist ?? "", title: song.title, library: library,
                                choose: choose, albumToo: true, length: song.duration)
        case let .lossless(song):
            SonicClient.GrabAsk(kind: .song, artist: song.artist ?? "", title: song.title, library: library,
                                choose: choose, length: song.duration, replace: song.id)
        }
    }
}

extension Song {
    /// A song the library has by itself: no album, or one named after it -- how a song got
    /// alone (a single, or one asked for from YouTube) is filed. Worth getting its album.
    var isOnItsOwn: Bool {
        guard let album, !album.isEmpty else { return true }
        let bare = { (text: String) in
            text.lowercased().filter { $0.isLetter || $0.isNumber }
        }
        let name = bare(album.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression))
        return name == bare(title) || name.hasPrefix(bare(title)) && name.hasSuffix("single")
    }

    /// Whether the file is lossy: worth getting again, lossless, in its place.
    var isLossy: Bool {
        guard let suffix = suffix?.lowercased() else { return false }
        return ["mp3", "m4a", "aac", "ogg", "oga", "opus", "wma", "mp4"].contains(suffix)
            && !(contentType ?? "").contains("alac")
    }
}
