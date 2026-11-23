import Foundation

/// The edition on the end of an album's name -- "(Vinyl rip)", "[Remastered]", "(Deluxe
/// Edition)" -- set apart, so a card shows it as a tag rather than cutting it off. Two
/// editions of one record, one in each library, looked like the same album twice: their
/// names differed only past where the card's line ended.
///
/// Only a group that says what edition it is: "(for Strings)" is part of a name.
enum AlbumEdition {
    static func split(_ name: String) -> (title: String, edition: String?) {
        var title = name.trimmingCharacters(in: .whitespaces)
        var editions: [String] = []
        while let group = trailingGroup(of: title), isEdition(group.inside) {
            let rest = title[..<group.start].trimmingCharacters(in: .whitespaces)
            guard !rest.isEmpty else { break }
            editions.insert(group.inside, at: 0)
            title = rest.hasSuffix("-") ? String(rest.dropLast()).trimmingCharacters(in: .whitespaces) : rest
        }
        return (title, editions.isEmpty ? nil : editions.joined(separator: " · "))
    }

    /// The bracketed group the name ends with, and where it starts.
    private static func trailingGroup(of name: String) -> (start: String.Index, inside: String)? {
        guard let last = name.last, last == ")" || last == "]" else { return nil }
        let open: Character = last == ")" ? "(" : "["
        guard let start = name.lastIndex(of: open) else { return nil }
        let inside = name[name.index(after: start)..<name.index(before: name.endIndex)]
            .trimmingCharacters(in: .whitespaces)
        return inside.isEmpty ? nil : (start, inside)
    }

    private static let words: Set<String> = [
        "deluxe", "edition", "version", "rip", "vinyl", "lp", "cd", "web", "mono", "stereo",
        "expanded", "anniversary", "bonus", "explicit", "clean", "reissue", "live", "demo",
        "demos", "acoustic", "instrumental", "instrumentals", "ep", "single", "special",
        "collector", "collectors", "limited", "super", "complete", "japan", "japanese",
        "import", "hires", "hi", "res", "bit", "flac", "soundtrack", "ost", "mix", "mixes",
        "remix", "remixes", "remixed", "sessions", "unplugged", "extended", "bootleg",
    ]

    static func isEdition(_ text: String) -> Bool {
        let tokens = text.lowercased()
            .folding(options: .diacriticInsensitive, locale: nil)
            .split { !$0.isLetter && !$0.isNumber }
        return tokens.contains { token in
            words.contains(String(token)) || token.hasPrefix("remaster") || token.hasSuffix("bit")
        }
    }
}
