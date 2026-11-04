import Foundation

/// Plexamp's Top Result: the one thing a search most probably meant, shown above the
/// lists. An exact name beats a prefix, and an artist beats an album beats a song at the
/// same strength — typing "Portishead" means the band before the album or the track.
enum SearchRanking {
    enum TopResult: Sendable {
        case artist(Artist)
        case album(Album)
        case song(Song)
    }

    static func topResult(for query: String, in results: SearchResult3) -> TopResult? {
        let wanted = comparable(query)
        guard !wanted.isEmpty else { return nil }

        if let artist = results.artists.first(where: { comparable($0.name) == wanted }) { return .artist(artist) }
        if let album = results.albums.first(where: { comparable($0.name) == wanted }) { return .album(album) }
        if let song = results.songs.first(where: { comparable($0.title) == wanted }) { return .song(song) }

        if let artist = results.artists.first(where: { comparable($0.name).hasPrefix(wanted) }) { return .artist(artist) }
        if let album = results.albums.first(where: { comparable($0.name).hasPrefix(wanted) }) { return .album(album) }
        if let song = results.songs.first(where: { comparable($0.title).hasPrefix(wanted) }) { return .song(song) }
        return nil
    }

    /// The results as they are shown: one copy of each, and in each section the names
    /// that are the query first, then those that start with it, then the server's order.
    ///
    /// One copy because the library's two folders overlap by about 40%, so "All" found
    /// most songs twice -- "Nineteen Cigarettes" by Postcards, twice, one under the other.
    /// And the order because `search3` ranks by its own idea of relevance: "k." listed
    /// "B.B.K." and "It's O.K." above the song actually called "K.".
    static func arranged(_ results: SearchResult3, for query: String) -> SearchResult3 {
        let wanted = comparable(query)
        return SearchResult3(
            artist: ranked(unique(results.artists) { comparable($0.name) }, wanted) { $0.name },
            album: ranked(unique(results.albums) { "\(comparable($0.name))\u{1F}\(comparable($0.artist ?? ""))" }, wanted) { $0.name },
            song: ranked(unique(results.songs) { "\(comparable($0.title))\u{1F}\(comparable($0.artist ?? ""))" }, wanted) { $0.title }
        )
    }

    /// One of each album by name and artist, the first kept. The library's two folders
    /// hold many albums twice, so lists in "All" showed them twice: checked on the server,
    /// 24 of Most Played's first 100 albums, 11 of the A-Z list's, 8 of Recently Played's.
    static func oneOfEach(_ albums: [Album]) -> [Album] {
        unique(albums) { "\(comparable($0.name))\u{1F}\(comparable($0.artist ?? ""))" }
    }

    /// An artist's other albums, for "More by": one of each, and not this one in either
    /// library. Filtering out only this album's id left its copy from the other library,
    /// and every other album twice.
    static func moreBy(_ albums: [Album], than current: Album) -> [Album] {
        let key = { (album: Album) in "\(comparable(album.name))\u{1F}\(comparable(album.artist ?? ""))" }
        let this = key(current)
        return oneOfEach(albums.filter { $0.id != current.id && key($0) != this })
    }

    /// One of each recording by title and artist, the first kept -- what mixes and
    /// playlists already treat as the same song. The two folders' copies of a song have
    /// different ids, so de-duplicating by id kept both.
    static func oneOfEach(_ songs: [Song]) -> [Song] {
        unique(songs) { "\(comparable($0.title))\u{1F}\(comparable($0.artist ?? ""))" }
    }

    /// For matching only: `normalised`, with punctuation gone and runs of spaces made
    /// one, so "k" is "K." and "dont stop" is "Don't Stop". Not used for sorting, which
    /// keeps `normalised`.
    static func comparable(_ text: String) -> String {
        let folded = normalised(text)
        var kept = String.UnicodeScalarView()
        kept.append(contentsOf: folded.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || CharacterSet.whitespaces.contains($0)
        })
        return String(kept).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// 2 for the query itself, 1 for a name that starts with it, 0 otherwise.
    private static func strength(_ name: String, _ wanted: String) -> Int {
        guard !wanted.isEmpty else { return 0 }
        let name = comparable(name)
        if name == wanted { return 2 }
        return name.hasPrefix(wanted) ? 1 : 0
    }

    /// Stable: within a strength, the server's order stands.
    private static func ranked<T>(_ items: [T], _ wanted: String, name: (T) -> String) -> [T] {
        items.enumerated()
            .map { (offset: $0.offset, item: $0.element, strength: strength(name($0.element), wanted)) }
            .sorted { $0.strength != $1.strength ? $0.strength > $1.strength : $0.offset < $1.offset }
            .map(\.item)
    }

    private static func unique<T>(_ items: [T], key: (T) -> String) -> [T] {
        var seen = Set<String>()
        return items.filter { seen.insert(key($0)).inserted }
    }

    /// Case, accents and a leading "The" do not decide what someone meant.
    static func normalised(_ text: String) -> String {
        var folded = text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if folded.hasPrefix("the ") { folded.removeFirst(4) }
        return folded
    }
}

extension SearchResult3 {
    /// These results, then whatever `other` found that these did not.
    func adding(_ other: SearchResult3) -> SearchResult3 {
        func merged<T>(_ mine: [T], _ theirs: [T], id: (T) -> String) -> [T] {
            let have = Set(mine.map(id))
            return mine + theirs.filter { !have.contains(id($0)) }
        }
        return SearchResult3(
            artist: merged(artists, other.artists) { $0.id },
            album: merged(albums, other.albums) { $0.id },
            song: merged(songs, other.songs) { $0.id }
        )
    }
}
