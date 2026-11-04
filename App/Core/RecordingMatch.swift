import Foundation

/// Which song in a list is a given recording, when only its title, artist and album are
/// known: for plays of songs the server no longer has (`HistoryRepair`).
enum RecordingMatch {
    /// By title, artist and album; failing that, by title and artist when every match is
    /// on one album, which is a song retagged onto its real album ("Singles" to "Petals
    /// to Thorns"). Punctuation does not count: "blink‐182" with a Unicode hyphen is
    /// blink-182.
    static func song(title: String, artist: String, album: String, in candidates: [Song]) -> Song? {
        let title = key(title), artist = key(artist)
        let matches = candidates.filter { key($0.title) == title && key($0.artist ?? "") == artist }
        if let exact = matches.first(where: { key($0.album ?? "") == key(album) }) { return exact }
        let albums = Set(matches.map { key($0.album ?? "") })
        return albums.count == 1 ? matches.first : nil
    }

    static func key(_ text: String) -> String {
        String(SearchRanking.normalised(text).unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }.map(Character.init))
    }
}
