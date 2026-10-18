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
        let wanted = normalised(query)
        guard !wanted.isEmpty else { return nil }

        if let artist = results.artists.first(where: { normalised($0.name) == wanted }) { return .artist(artist) }
        if let album = results.albums.first(where: { normalised($0.name) == wanted }) { return .album(album) }
        if let song = results.songs.first(where: { normalised($0.title) == wanted }) { return .song(song) }

        if let artist = results.artists.first(where: { normalised($0.name).hasPrefix(wanted) }) { return .artist(artist) }
        if let album = results.albums.first(where: { normalised($0.name).hasPrefix(wanted) }) { return .album(album) }
        if let song = results.songs.first(where: { normalised($0.title).hasPrefix(wanted) }) { return .song(song) }
        return nil
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
