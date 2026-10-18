import Foundation

/// `getAlbumList2` sort orders. Only the ones the UI offers are listed.
enum AlbumSort: String, CaseIterable, Identifiable, Sendable {
    case recent
    case newest
    case frequent
    case alphabeticalByName
    case random

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recent: return "Recently Played"
        case .newest: return "Recently Added"
        case .frequent: return "Most Played"
        case .alphabeticalByName: return "A–Z"
        case .random: return "Random"
        }
    }
}

// MARK: - Library items

/// The key a Subsonic response nests its payload under, so the envelope decoder can
/// reach through one generic layer instead of every model spelling out a wrapper.
protocol PayloadKeyed {
    static var payloadKey: String { get }
}

struct Album: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    var artist: String?
    var artistId: String?
    var coverArt: String?
    var songCount: Int?
    var duration: Int?
    var year: Int?
    var genre: String?
    var starred: String?

    // OpenSubsonic. Every one optional and appended, so a cached album written before they
    // existed still decodes, and a server that predates them simply leaves them nil.
    var playCount: Int?
    /// ISO timestamp of the last play.
    var played: String?
    var userRating: Int?
    /// When it was added to the library.
    var created: String?
    /// MusicBrainz release types, lowercased by Navidrome: "album", "single", "ep",
    /// "compilation", "live", "soundtrack", "remix"… What lets an artist page split
    /// Albums from Singles & EPs the way Plexamp does.
    var releaseTypes: [String]?
    var recordLabels: [NamedItem]?
    var isCompilation: Bool?
    var genres: [NamedItem]?
    var moods: [String]?
    var originalReleaseDate: ItemDate?
    var releaseDate: ItemDate?

    var isFavorite: Bool { starred != nil }
    var lastPlayedAt: Date? { ServerDate.parse(played) }
    var addedAt: Date? { ServerDate.parse(created) }
    var kind: ReleaseKind { ReleaseKind(album: self) }
}

/// `{ "name": "Warp" }` — the shape OpenSubsonic uses for genres and record labels alike.
struct NamedItem: Codable, Hashable, Sendable {
    let name: String
}

/// A release date broken into parts, any of which may be missing: plenty of tags carry a
/// year and nothing else.
struct ItemDate: Codable, Hashable, Sendable {
    var year: Int?
    var month: Int?
    var day: Int?
}

/// An `{ "id", "name" }` pair for one of a track's several credited artists.
struct ArtistLink: Codable, Hashable, Sendable {
    let id: String
    let name: String
}

/// Volume normalisation data, read from the file's ReplayGain or R128 tags by the server.
///
/// Decibels relative to the ReplayGain 2.0 reference of −18 LUFS: a loud modern master
/// typically carries a gain around −8, a quiet 1970s pressing something positive.
/// Peaks are linear, 1.0 being full scale.
struct ReplayGain: Codable, Hashable, Sendable {
    var trackGain: Double?
    var albumGain: Double?
    var trackPeak: Double?
    var albumPeak: Double?
    /// A gain the server applies on top, for formats whose tags are relative to a
    /// different reference (Opus R128). Usually absent or zero.
    var baseGain: Double?
}

/// How an artist page groups its releases. Plexamp splits a discography into Albums,
/// Singles & EPs, Live, Compilations and so on; this is the same split, read from the
/// release types the server reports. Case order is the order on the page.
enum ReleaseKind: String, CaseIterable, Sendable {
    case album
    case singleOrEP
    case live
    case compilation
    case soundtrack
    case remix
    case other

    var title: String {
        switch self {
        case .album: return "Albums"
        case .singleOrEP: return "Singles & EPs"
        case .live: return "Live"
        case .compilation: return "Compilations"
        case .soundtrack: return "Soundtracks"
        case .remix: return "Remixes"
        case .other: return "Other"
        }
    }

    /// The first type that settles it, in precedence order. A live compilation is filed as
    /// live, and a soundtrack single as a soundtrack, because those are the words that
    /// describe what it sounds like. With no types at all it is an album: that is what
    /// every release was before tags said otherwise.
    init(album: Album) {
        let types = Set((album.releaseTypes ?? []).map { $0.lowercased() })
        if types.contains("live") {
            self = .live
        } else if types.contains("soundtrack") {
            self = .soundtrack
        } else if types.contains("compilation") || album.isCompilation == true {
            self = .compilation
        } else if types.contains("remix") {
            self = .remix
        } else if types.contains("single") || types.contains("ep") {
            self = .singleOrEP
        } else if types.isEmpty || types.contains("album") {
            self = .album
        } else {
            self = .other
        }
    }
}

struct Song: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    var album: String?
    var albumId: String?
    var artist: String?
    var artistId: String?
    var coverArt: String?
    var duration: Int?
    var track: Int?
    var discNumber: Int?
    var year: Int?
    var genre: String?
    var size: Int64?
    var suffix: String?
    var contentType: String?
    var bitRate: Int?
    /// Present on OpenSubsonic servers. Together these are what turns a bare "FLAC"
    /// badge into "FLAC 24/96", which is the readout that actually answers "is this
    /// lossless".
    var bitDepth: Int?
    var samplingRate: Int?
    var channelCount: Int?
    var starred: String?
    var userRating: Int?
    var playCount: Int?

    // OpenSubsonic, optional and appended for the same reason as on `Album`.
    var replayGain: ReplayGain?
    /// ISO timestamp of the last play.
    var played: String?
    var created: String?
    var bpm: Int?
    var comment: String?
    var genres: [NamedItem]?
    var moods: [String]?
    /// Every credited track artist, where `artist` is one display string.
    var artists: [ArtistLink]?
    var albumArtists: [ArtistLink]?
    var displayArtist: String?

    var isFavorite: Bool { starred != nil }
    var lastPlayedAt: Date? { ServerDate.parse(played) }

    /// Stable sort key that keeps multi-disc albums in playing order.
    var albumOrder: Int { (discNumber ?? 1) * 1000 + (track ?? 0) }

    /// The album artist when the server says who that is, else the track artist. What
    /// "same artist" means for a DJ or a mix: a guest verse should not count as a new
    /// artist.
    var primaryArtistID: String? { albumArtists?.first?.id ?? artistId }
}

struct Artist: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    var albumCount: Int?
    var coverArt: String?
    var artistImageUrl: String?
    var starred: String?
}

struct MusicFolder: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    let name: String
}

struct Playlist: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    var comment: String?
    var owner: String?
    var songCount: Int?
    var duration: Int?
    var coverArt: String?
    var changed: String?
}

struct Genre: Codable, Hashable, Sendable, Identifiable {
    let value: String
    var songCount: Int?
    var albumCount: Int?

    var id: String { value }
}

// MARK: - Lightweight navigation references
//
// Pushed onto NavigationStack instead of full models: cheap to hash, and a search
// result can navigate without first fetching a complete payload.

struct AlbumRef: Hashable, Sendable {
    let id: String
    let name: String
    var artist: String?
    var coverArt: String?

    init(id: String, name: String, artist: String? = nil, coverArt: String? = nil) {
        self.id = id
        self.name = name
        self.artist = artist
        self.coverArt = coverArt
    }

    init(_ album: Album) {
        self.init(id: album.id, name: album.name, artist: album.artist, coverArt: album.coverArt)
    }
}

struct ArtistRef: Hashable, Sendable {
    let id: String
    let name: String
    var coverArt: String?

    init(id: String, name: String, coverArt: String? = nil) {
        self.id = id
        self.name = name
        self.coverArt = coverArt
    }

    init(_ artist: Artist) {
        self.init(id: artist.id, name: artist.name, coverArt: artist.coverArt)
    }
}

struct PlaylistRef: Hashable, Sendable {
    let id: String
    let name: String
    var coverArt: String?

    init(id: String, name: String, coverArt: String? = nil) {
        self.id = id
        self.name = name
        self.coverArt = coverArt
    }

    init(_ playlist: Playlist) {
        self.init(id: playlist.id, name: playlist.name, coverArt: playlist.coverArt)
    }
}

// MARK: - Envelope payloads
//
// Every list field stays optional with a `?? []` accessor: Navidrome omits the key
// entirely rather than returning an empty array when there are no results.

struct MusicFolders: Decodable, PayloadKeyed, Sendable {
    let musicFolder: [MusicFolder]?
    static var payloadKey: String { "musicFolders" }
}

struct AlbumList2: Decodable, PayloadKeyed, Sendable {
    let album: [Album]?
    static var payloadKey: String { "albumList2" }
}

struct AlbumDetail: Codable, PayloadKeyed, Identifiable, Sendable {
    let id: String
    let name: String
    var artist: String?
    var artistId: String?
    var coverArt: String?
    var songCount: Int?
    var duration: Int?
    var year: Int?
    var genre: String?
    var starred: String?
    var song: [Song]?

    var playCount: Int?
    var played: String?
    var userRating: Int?
    var created: String?
    var releaseTypes: [String]?
    var recordLabels: [NamedItem]?
    var isCompilation: Bool?
    var genres: [NamedItem]?
    var moods: [String]?
    var originalReleaseDate: ItemDate?
    var releaseDate: ItemDate?

    static var payloadKey: String { "album" }

    var songs: [Song] { (song ?? []).sorted { $0.albumOrder < $1.albumOrder } }
    var isFavorite: Bool { starred != nil }
    var hasMultipleDiscs: Bool { Set(songs.map { $0.discNumber ?? 1 }).count > 1 }

    /// The list-row form of this album, for anything that only takes an `Album`.
    var summary: Album {
        Album(
            id: id, name: name, artist: artist, artistId: artistId, coverArt: coverArt,
            songCount: songCount, duration: duration, year: year, genre: genre,
            starred: starred, playCount: playCount, played: played, userRating: userRating,
            created: created, releaseTypes: releaseTypes, recordLabels: recordLabels,
            isCompilation: isCompilation, genres: genres, moods: moods,
            originalReleaseDate: originalReleaseDate, releaseDate: releaseDate
        )
    }
}

struct ArtistIndex: Codable, Hashable, Sendable, Identifiable {
    let name: String
    let artist: [Artist]?

    var id: String { name }
    var artists: [Artist] { artist ?? [] }
}

/// `getIndexes`: the library's top-level folders, by letter. The same shape as the
/// artist index, which is what a top-level folder was in the original Subsonic.
struct FolderIndexes: Decodable, PayloadKeyed, Sendable {
    let index: [ArtistIndex]?
    static var payloadKey: String { "indexes" }
}

/// `getMusicDirectory`: one folder, its subfolders and its files.
struct MusicDirectory: Decodable, PayloadKeyed, Sendable {
    let id: String
    let name: String
    var parent: String?
    var child: [DirectoryChild]?

    static var payloadKey: String { "directory" }

    var folders: [DirectoryChild] { (child ?? []).filter(\.isDir) }
    var songs: [Song] { (child ?? []).filter { !$0.isDir }.map(\.song).sorted { $0.albumOrder < $1.albumOrder } }
}

/// A folder entry: a subfolder or a file. Both carry a song's fields — a subfolder its
/// title and cover — so the entry is decoded as a song plus the one flag that tells them
/// apart.
struct DirectoryChild: Decodable, Identifiable, Sendable {
    let isDir: Bool
    let song: Song

    var id: String { song.id }

    private enum CodingKeys: String, CodingKey { case isDir }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isDir = try container.decodeIfPresent(Bool.self, forKey: .isDir) ?? false
        song = try Song(from: decoder)
    }
}

struct ArtistsRoot: Decodable, PayloadKeyed, Sendable {
    let index: [ArtistIndex]?
    static var payloadKey: String { "artists" }
}

struct ArtistDetail: Codable, PayloadKeyed, Identifiable, Sendable {
    let id: String
    let name: String
    var coverArt: String?
    var artistImageUrl: String?
    var albumCount: Int?
    var starred: String?
    var album: [Album]?

    static var payloadKey: String { "artist" }

    /// Newest first: for an artist you almost always want the latest release.
    var albums: [Album] { (album ?? []).sorted { ($0.year ?? 0) > ($1.year ?? 0) } }
    var isFavorite: Bool { starred != nil }
}

/// `getArtistInfo2`. Everything here comes from the server's metadata agents (Last.fm,
/// Spotify) and is empty on a server without them configured — which is a normal state,
/// not an error, so every field is optional and the page shows what there is.
struct ArtistInfo: Codable, PayloadKeyed, Sendable {
    var biography: String?
    var musicBrainzId: String?
    var lastFmUrl: String?
    var largeImageUrl: String?
    var similarArtist: [Artist]?

    static var payloadKey: String { "artistInfo2" }

    var similarArtists: [Artist] { similarArtist ?? [] }

    var plainBiography: String? { ServerText.plain(biography) }
}

/// `getAlbumInfo2`: Plexamp's "Album Review", when the server's agents have one.
struct AlbumInfo: Codable, PayloadKeyed, Sendable {
    var notes: String?
    var musicBrainzId: String?
    var lastFmUrl: String?

    static var payloadKey: String { "albumInfo" }

    var plainNotes: String? { ServerText.plain(notes) }
}

/// Prose from the server's metadata agents, without its markup.
enum ServerText {
    /// Last.fm text ends with a "Read more on Last.fm" anchor. The prose is worth showing;
    /// the link and the tags are not. Nil for anything that is empty once they are gone.
    static func plain(_ html: String?) -> String? {
        guard var text = html?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else { return nil }
        if let anchor = text.range(of: "<a ") { text = String(text[..<anchor.lowerBound]) }
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

struct TopSongs: Decodable, PayloadKeyed, Sendable {
    let song: [Song]?
    static var payloadKey: String { "topSongs" }
}

struct Playlists: Decodable, PayloadKeyed, Sendable {
    let playlist: [Playlist]?
    static var payloadKey: String { "playlists" }
}

struct PlaylistDetail: Codable, PayloadKeyed, Identifiable, Sendable {
    let id: String
    let name: String
    var comment: String?
    var owner: String?
    var songCount: Int?
    var duration: Int?
    var coverArt: String?
    var entry: [Song]?

    static var payloadKey: String { "playlist" }

    /// Playlist order is the server's order -- never re-sorted.
    var songs: [Song] { entry ?? [] }
}

struct Genres: Decodable, PayloadKeyed, Sendable {
    let genre: [Genre]?
    static var payloadKey: String { "genres" }
}

struct SongsByGenre: Decodable, PayloadKeyed, Sendable {
    let song: [Song]?
    static var payloadKey: String { "songsByGenre" }
}

struct Starred2: Codable, PayloadKeyed, Sendable {
    var song: [Song]?
    var album: [Album]?
    var artist: [Artist]?

    static var payloadKey: String { "starred2" }

    var songs: [Song] { song ?? [] }
    var albums: [Album] { album ?? [] }
    var artists: [Artist] { artist ?? [] }
}

struct RandomSongs: Decodable, PayloadKeyed, Sendable {
    let song: [Song]?
    static var payloadKey: String { "randomSongs" }
}

struct SearchResult3: Codable, PayloadKeyed, Sendable {
    var artist: [Artist]?
    var album: [Album]?
    var song: [Song]?

    static var payloadKey: String { "searchResult3" }

    var artists: [Artist] { artist ?? [] }
    var albums: [Album] { album ?? [] }
    var songs: [Song] { song ?? [] }
    var isEmpty: Bool { artists.isEmpty && albums.isEmpty && songs.isEmpty }
}

// MARK: - Lyrics

struct LyricsList: Decodable, PayloadKeyed, Sendable {
    let structuredLyrics: [StructuredLyrics]?
    static var payloadKey: String { "lyricsList" }
}

/// Decoded tolerantly on purpose: the songLyrics v2 extension may add word-level
/// timing fields, and unknown keys must not break decoding. Encodable too, because
/// lyrics are cached to disk alongside downloaded audio.
struct StructuredLyrics: Codable, Hashable, Sendable {
    var displayArtist: String?
    var displayTitle: String?
    var lang: String?
    /// Milliseconds, applied to every line in this set.
    var offset: Int?
    var synced: Bool
    var line: [LyricLine]?

    var lines: [LyricLine] { line ?? [] }
}

/// The server's copy of the play queue, shared by every client on this account.
struct SavedQueue: Codable, PayloadKeyed, Sendable {
    var entry: [Song]?
    /// Song id of the track that was playing.
    var current: String?
    /// Milliseconds into `current`.
    var position: Int?
    /// ISO timestamp of the last save, used to decide whose queue is newer.
    var changed: String?
    /// The `c=` client name that saved it. Ours is skipped, so the app never adopts
    /// its own save back over a queue the user has since changed locally.
    var changedBy: String?

    static var payloadKey: String { "playQueue" }

    var songs: [Song] { entry ?? [] }

    var changedAt: Date? { ServerDate.parse(changed) }
}

/// Parses the timestamps Navidrome returns.
///
/// A shared static formatter would be simpler and is what I reached for first, but
/// `ISO8601DateFormatter` is a mutable class and not `Sendable`, so a `static let` of one
/// is a data race under strict concurrency. Building one per call is cheap next to the
/// network request that produced the string.
enum ServerDate {
    static func parse(_ value: String?) -> Date? {
        guard let value else { return nil }

        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: value) { return date }

        // Navidrome includes fractional seconds, which the default options reject.
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value)
    }
}

/// A track another client is playing right now. The song fields are inlined by the
/// server rather than nested, so this repeats them rather than embedding a `Song`.
struct NowPlayingEntry: Codable, Identifiable, Sendable {
    let id: String
    var title: String?
    var artist: String?
    var album: String?
    var coverArt: String?
    /// Which client, e.g. "Feishin" or "Music".
    var playerName: String?
    var username: String?
    /// Minutes since it started.
    var minutesAgo: Int?
}

struct NowPlayingList: Codable, PayloadKeyed, Sendable {
    var entry: [NowPlayingEntry]?
    static var payloadKey: String { "nowPlaying" }
}

struct ScanStatus: Codable, PayloadKeyed, Sendable {
    var scanning: Bool
    var count: Int?
    var folderCount: Int?
    var lastScan: String?
    var scanType: String?
    var elapsedTime: Int?

    static var payloadKey: String { "scanStatus" }

    var lastScanAt: Date? { ServerDate.parse(lastScan) }
}

struct CreatedPlaylist: Decodable, PayloadKeyed, Sendable {
    let playlist: Playlist
    static var payloadKey: String { "playlist" }

    /// The payload *is* the playlist, so the key is consumed by the envelope and this
    /// wrapper decodes from the same object rather than from a nested one.
    init(from decoder: Decoder) throws {
        playlist = try Playlist(from: decoder)
    }
}

struct SimilarSongs: Decodable, PayloadKeyed, Sendable {
    let song: [Song]?
    static var payloadKey: String { "similarSongs2" }
}

/// `getSong.view` — verified against this server. The one lookup the app needs when it
/// holds a song id and nothing else: a lyric-search hit, a resume bookmark, a Siri request
/// that named a track.
struct FetchedSong: Decodable, PayloadKeyed, Sendable {
    let song: Song
    static var payloadKey: String { "song" }

    /// Same shape as `CreatedPlaylist`: the payload *is* the song, so the key is consumed
    /// by the envelope and this decodes from the same object rather than a nested one.
    init(from decoder: Decoder) throws {
        song = try Song(from: decoder)
    }
}

/// A per-track resume position.
///
/// **Not** `savePlayQueue`, which stores one position for the whole queue and is how this
/// app and desktop Feishin share a session. A bookmark is per song, survives the queue
/// being replaced, and is what a two-hour live set or a DJ mix needs. Don't merge them.
struct BookmarkList: Decodable, PayloadKeyed, Sendable {
    var bookmark: [Bookmark]?
    static var payloadKey: String { "bookmarks" }
}

struct Bookmark: Decodable, Sendable, Identifiable {
    let entry: Song
    /// Milliseconds — the unit `savePlayQueue` uses, not the seconds `scrobble` wants.
    let position: Int
    var comment: String?
    var created: String?
    var changed: String?

    var id: String { entry.id }
    var seconds: Double { Double(position) / 1_000 }
}

struct LyricLine: Codable, Hashable, Sendable {
    /// Milliseconds from the start of the track. Absent on unsynced lyrics.
    var start: Int?
    let value: String
}

// MARK: - Formatting

extension Int {
    /// Seconds as `m:ss`.
    var asDuration: String {
        let minutes = self / 60
        let seconds = self % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// Seconds as a human total, e.g. `1 hr 23 min` or `47 min`.
    var asLongDuration: String {
        let hours = self / 3600
        let minutes = (self % 3600) / 60
        if hours > 0 { return "\(hours) hr \(minutes) min" }
        return "\(minutes) min"
    }
}

extension Int64 {
    var asFileSize: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: self)
    }
}
