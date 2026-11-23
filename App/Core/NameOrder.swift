import Foundation

/// A–Z as a reader files a name: case, accents, leading punctuation and a leading "The",
/// "A" or "An" set aside. The server sorts albums by the name as typed, so a title in
/// quotes came before every letter, and one starting "The" sat under T.
enum NameOrder {
    static func key(_ name: String) -> String {
        var folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        folded = String(folded.drop { !$0.isLetter && !$0.isNumber })
        for article in ["the ", "a ", "an "] where folded.hasPrefix(article) {
            let rest = String(folded.dropFirst(article.count).drop { !$0.isLetter && !$0.isNumber })
            if !rest.isEmpty { folded = rest }
            break
        }
        return folded
    }

    /// The letter it is filed under, or "#" for a digit or a script with no A–Z.
    static func letter(_ name: String) -> String {
        guard let first = key(name).unicodeScalars.first, ("a"..."z").contains(first) else { return "#" }
        return String(first).uppercased()
    }

    /// In that order, numbers by their value ("2" before "10"); the same name by artist.
    static func sorted(_ albums: [Album]) -> [Album] {
        let keyed = albums.map { (album: $0, key: key($0.name), artist: key($0.artist ?? "")) }
        return keyed.sorted { a, b in
            // "#" first, as the rail has it: a letter-less key sorts before the letters.
            let aLetter = letter(a.album.name) != "#", bLetter = letter(b.album.name) != "#"
            if aLetter != bLetter { return !aLetter }
            let order = a.key.localizedStandardCompare(b.key)
            if order != .orderedSame { return order == .orderedAscending }
            return a.artist.localizedStandardCompare(b.artist) == .orderedAscending
        }.map(\.album)
    }
}
