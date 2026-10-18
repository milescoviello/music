import Foundation

/// The Downloads screen as Plexamp lays it out: what is on the phone as the albums and
/// playlists it was downloaded as — folders to open, never every song at once.
///
/// Built from the catalog alone, so it works with the server switched off, and built
/// once per catalog change rather than on every redraw: at a few thousand songs, grouping
/// inside a view's `body` is precisely the lag this replaced.
///
/// What goes where:
/// - **Albums**: an album download, and any song downloaded on its own — a single song
///   lands in its album's folder rather than as a loose row. An album's folder also
///   shows that album's songs that arrived with a playlist, because a song already on the
///   phone is skipped when its album is downloaded, and the folder would otherwise be
///   missing exactly those tracks.
/// - **Playlists**: everything downloaded under any other group — playlists, Favourites,
///   daily mixes. In the playlist's own order when a copy of it is cached, since the
///   catalog only records when each track arrived.
struct DownloadFolders: Sendable {
    enum Kind: String, Sendable, CaseIterable {
        case album
        case playlist
    }

    /// Plexamp's `downloadsSort`. Its default is `addedAt`, ascending: oldest first, so a
    /// folder that arrives while you are looking joins the end instead of shoving
    /// everything you were reading down the screen.
    enum Sort: String, Sendable, CaseIterable {
        case addedAt
        case name

        var title: String {
            switch self {
            case .addedAt: return "Date Added"
            case .name: return "Name"
            }
        }
    }

    struct Folder: Identifiable, Sendable {
        /// Kind-qualified, so an album and a playlist that happen to share an id stay apart.
        let id: String
        let kind: Kind
        /// The album id, or the group id the playlist was downloaded under.
        let key: String
        let name: String
        /// Nil for a playlist, whose row shows its track count instead.
        let artist: String?
        let coverArt: String?
        /// On the phone, in playing order.
        let songs: [Song]
        /// Asked for and not here yet, in the same order.
        let waiting: [Song]
        /// What is on disk; a transfer still running has no size worth showing.
        let byteCount: Int64
        let duration: Int
        /// When the first of it was asked for. The earliest rather than the latest, so a
        /// folder that is still filling up keeps its place instead of jumping to the end
        /// with every track that lands.
        let addedAt: Date
        /// Folded once here, so neither sorting nor search folds per keystroke.
        let sortKey: String
        let searchKey: String

        var trackCount: Int { songs.count + waiting.count }
        var isDownloading: Bool { !waiting.isEmpty }

        /// Whole tracks, like Plexamp's ring. It moves when a track lands and never
        /// needs the per-chunk transfer progress, which changes many times a second and
        /// would redraw every row that read it.
        var fractionDone: Double {
            trackCount == 0 ? 1 : Double(songs.count) / Double(trackCount)
        }
    }

    struct SearchResults: Sendable {
        var albums: [Folder] = []
        var playlists: [Folder] = []
        var songs: [Song] = []

        var isEmpty: Bool { albums.isEmpty && playlists.isEmpty && songs.isEmpty }
    }

    /// Oldest first; `sorted(_:by:ascending:)` gives any other order.
    private(set) var albums: [Folder] = []
    private(set) var playlists: [Folder] = []
    /// Every downloaded song once, by artist, album and track — the order search shows.
    private(set) var songs: [Song] = []
    private(set) var totalBytes: Int64 = 0
    private(set) var totalDuration = 0

    private var songKeys: [String] = []
    private var byID: [String: Folder] = [:]
    /// How many folders each song is in, so removing one folder never takes a song
    /// another folder still shows.
    private var memberships: [String: Int] = [:]

    var isEmpty: Bool { albums.isEmpty && playlists.isEmpty }

    init() {}

    /// - Parameter playlistOrders: Song ids in playlist order, keyed by playlist id, for
    ///   the playlists a copy is cached of.
    init(catalog: DownloadCatalog, playlistOrders: [String: [String]] = [:]) {
        struct Item {
            let entry: DownloadCatalog.Entry
            let isDone: Bool
            var song: Song { entry.song }
        }

        // A song is either here or on its way; if both somehow, it is here.
        var items: [String: Item] = [:]
        for entry in catalog.pending.values {
            items[entry.song.id] = Item(entry: entry, isDone: false)
        }
        for entry in catalog.entries.values {
            items[entry.song.id] = Item(entry: entry, isDone: true)
        }

        // An album download is grouped under its album id. Recognised from the songs
        // themselves rather than by guessing at the shape of an id: a group is an album
        // when one of its songs says it belongs to an album of that id.
        var albumGroups: Set<String> = []
        for item in items.values {
            if let group = item.entry.groupID, group == item.song.albumId {
                albumGroups.insert(group)
            }
        }

        var byAlbum: [String: [Item]] = [:]
        var albumsAsked: [String: [Item]] = [:]
        var playlistsAsked: [String: [Item]] = [:]
        for item in items.values {
            byAlbum[Self.albumKey(item.song), default: []].append(item)
            if let group = item.entry.groupID, !albumGroups.contains(group) {
                playlistsAsked[group, default: []].append(item)
            } else {
                albumsAsked[item.entry.groupID ?? Self.albumKey(item.song), default: []].append(item)
            }
        }

        func split(_ members: [Item]) -> (songs: [Song], waiting: [Song], bytes: Int64, duration: Int) {
            var songs: [Song] = []
            var waiting: [Song] = []
            var bytes: Int64 = 0
            var duration = 0
            for item in members {
                if item.isDone {
                    songs.append(item.song)
                    bytes += item.entry.byteCount
                    duration += item.song.duration ?? 0
                } else {
                    waiting.append(item.song)
                }
            }
            return (songs, waiting, bytes, duration)
        }

        var albums: [Folder] = []
        for (key, asked) in albumsAsked {
            var seen = Set<String>()
            let members = (asked + (byAlbum[key] ?? []))
                .filter { seen.insert($0.song.id).inserted }
                .sorted { Self.playingOrder($0.song, $1.song) }
            let parts = split(members)
            let songs = members.map(\.song)
            let name = songs.lazy.compactMap(\.album).first
                ?? asked.lazy.compactMap(\.entry.groupName).first
                ?? "Unknown Album"
            let artist = Self.albumArtist(songs)

            albums.append(Folder(
                id: "\(Kind.album.rawValue):\(key)",
                kind: .album,
                key: key,
                name: name,
                artist: artist,
                coverArt: songs.lazy.compactMap(\.coverArt).first,
                songs: parts.songs,
                waiting: parts.waiting,
                byteCount: parts.bytes,
                duration: parts.duration,
                addedAt: asked.map(\.entry.addedAt).min() ?? .distantPast,
                sortKey: SearchRanking.normalised(name),
                searchKey: Self.fold("\(name) \(artist ?? "")")
            ))
        }

        var playlists: [Folder] = []
        for (key, asked) in playlistsAsked {
            // The catalog keeps when each track arrived, not where it sits in the
            // playlist; that order comes from a cached copy of the playlist when there is
            // one. A cached copy also brings in tracks that were already on the phone for
            // another reason when the playlist was downloaded, and so were never filed
            // under it.
            let arrived = asked.sorted { ($0.entry.addedAt, $0.song.id) < ($1.entry.addedAt, $1.song.id) }
            var seen = Set<String>()
            var members: [Item] = []
            for id in playlistOrders[key] ?? [] {
                if let item = items[id], seen.insert(id).inserted { members.append(item) }
            }
            for item in arrived where seen.insert(item.song.id).inserted {
                members.append(item)
            }

            let parts = split(members)
            let name = asked.lazy.compactMap(\.entry.groupName).first
                ?? (key == "favourites" ? "Favourites" : "Playlist")

            playlists.append(Folder(
                id: "\(Kind.playlist.rawValue):\(key)",
                kind: .playlist,
                key: key,
                name: name,
                artist: nil,
                coverArt: members.lazy.compactMap(\.song.coverArt).first,
                songs: parts.songs,
                waiting: parts.waiting,
                byteCount: parts.bytes,
                duration: parts.duration,
                addedAt: asked.map(\.entry.addedAt).min() ?? .distantPast,
                sortKey: SearchRanking.normalised(name),
                searchKey: Self.fold(name)
            ))
        }

        let oldestFirst: (Folder, Folder) -> Bool = { ($0.addedAt, $0.id) < ($1.addedAt, $1.id) }
        self.albums = albums.sorted(by: oldestFirst)
        self.playlists = playlists.sorted(by: oldestFirst)

        for folder in albums + playlists {
            byID[folder.id] = folder
            for song in folder.songs + folder.waiting {
                memberships[song.id, default: 0] += 1
            }
        }

        // Keys folded once per song, not once per comparison.
        let keyed = catalog.entries.values.map { entry in
            let song = entry.song
            return (
                song: song,
                artist: SearchRanking.normalised(song.artist ?? ""),
                album: SearchRanking.normalised(song.album ?? ""),
                search: Self.fold("\(song.title) \(song.artist ?? "") \(song.album ?? "")")
            )
        }
        .sorted { lhs, rhs in
            if lhs.artist != rhs.artist { return lhs.artist < rhs.artist }
            if lhs.album != rhs.album { return lhs.album < rhs.album }
            return Self.playingOrder(lhs.song, rhs.song)
        }
        let downloaded = keyed.map { $0.song }
        songs = downloaded
        songKeys = keyed.map { $0.search }
        totalBytes = catalog.totalBytes
        totalDuration = downloaded.reduce(0) { $0 + ($1.duration ?? 0) }
    }

    // MARK: - Reading

    func folder(id: String) -> Folder? {
        byID[id]
    }

    func sorted(_ folders: [Folder], by sort: Sort, ascending: Bool) -> [Folder] {
        switch sort {
        case .addedAt:
            return ascending ? folders : folders.reversed()
        case .name:
            return folders.sorted { lhs, rhs in
                let order = lhs.sortKey.localizedStandardCompare(rhs.sortKey)
                if order == .orderedSame { return lhs.id < rhs.id }
                return (order == .orderedAscending) == ascending
            }
        }
    }

    /// Plexamp's Play All: every folder in the order shown, each song once.
    func playAll(sort: Sort, ascending: Bool) -> [Song] {
        var seen = Set<String>()
        return (sorted(albums, by: sort, ascending: ascending) + sorted(playlists, by: sort, ascending: ascending))
            .flatMap(\.songs)
            .filter { seen.insert($0.id).inserted }
    }

    /// Every word has to appear somewhere — title, artist or album — so "ok radiohead"
    /// finds OK Computer. Case and accents never decide it.
    func search(_ query: String) -> SearchResults {
        let words = Self.fold(query).split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return SearchResults() }
        let matches: (String) -> Bool = { key in words.allSatisfy { key.contains($0) } }

        var results = SearchResults()
        results.albums = albums.filter { matches($0.searchKey) }
        results.playlists = playlists.filter { matches($0.searchKey) }
        results.songs = zip(songs, songKeys).compactMap { matches($1) ? $0 : nil }
        return results
    }

    /// What removing this folder deletes: its songs that no other folder shows. Taking a
    /// playlist off the phone must not leave a hole in an album downloaded on its own,
    /// and the reverse.
    func songIDsToRemove(for folder: Folder) -> [String] {
        (folder.songs + folder.waiting)
            .map(\.id)
            .filter { (memberships[$0] ?? 0) <= 1 }
    }

    // MARK: - Helpers

    static func albumKey(_ song: Song) -> String {
        song.albumId ?? "album-\(song.album ?? song.id)"
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private static func playingOrder(_ lhs: Song, _ rhs: Song) -> Bool {
        if lhs.albumOrder != rhs.albumOrder { return lhs.albumOrder < rhs.albumOrder }
        return (lhs.title, lhs.id) < (rhs.title, rhs.id)
    }

    /// Who an album is by: the album artist when the server says, else the track artist
    /// when they all agree, else a compilation.
    private static func albumArtist(_ songs: [Song]) -> String? {
        if let albumArtist = songs.lazy.compactMap({ $0.albumArtists?.first?.name }).first {
            return albumArtist
        }
        let artists = Set(songs.compactMap(\.artist))
        if artists.count > 1 { return "Various Artists" }
        return artists.first
    }
}
