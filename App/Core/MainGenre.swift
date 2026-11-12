import Foundation

/// Which of a song's genres says the most about it.
///
/// Tags list several genres, and the first is often an umbrella one: "Rock", or "Pop"
/// that the server split out of "Pop/Rock". Navidrome hands that first one over as the
/// song's `genre`, so a grunge record counted as Pop in mixes and stats. The genre that
/// describes it is the first one no other listed genre narrows down: in "Rock, Hard
/// Rock, Grunge", "Hard Rock" covers "Rock", so "Hard Rock" wins.
enum MainGenre {
    /// YouTube upload categories that downloaders write into the genre tag. They describe
    /// the video, not the music.
    static let notGenres: Set<String> = [
        "music", "people & blogs", "film & animation", "entertainment", "gaming", "comedy",
        "education", "howto & style", "news & politics", "nonprofits & activism",
        "science & technology", "sports", "travel & events", "autos & vehicles", "pets & animals",
    ]

    /// The real genres in the order the tags gave them: blanks, bare ID3 genre numbers,
    /// video categories and case-only repeats dropped.
    static func usable(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.compactMap { raw in
            let name = raw.replacingOccurrences(of: "\u{00A0}", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let key = name.lowercased()
            guard !name.isEmpty, !notGenres.contains(key), !name.allSatisfy(\.isNumber),
                  seen.insert(key).inserted else { return nil }
            return name
        }
    }

    static func pick(_ names: [String]) -> String? {
        let genres = usable(names)
        let words = genres.map(Self.words)
        for (index, own) in words.enumerated() {
            let narrowed = words.indices.contains { other in
                other != index && own.isStrictSubset(of: words[other])
            }
            if !narrowed { return genres[index] }
        }
        return genres.first
    }

    /// "Synth-Pop" and "synth pop" are the same words; "Pop" is one of them.
    static func words(_ name: String) -> Set<String> {
        Set(name.lowercased()
            .split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "/" })
            .map(String.init))
    }

    /// Whether `genre` is any of the item's genres, not only the first.
    static func contains(_ genres: [NamedItem]?, first: String?, _ genre: String) -> Bool {
        usable(names(genres, first: first)).contains { $0.caseInsensitiveCompare(genre) == .orderedSame }
    }

    /// The OpenSubsonic list when the server sent one, else the single `genre`.
    static func names(_ genres: [NamedItem]?, first: String?) -> [String] {
        if let genres, !genres.isEmpty { return genres.map(\.name) }
        return [first].compactMap { $0 }
    }
}

extension Song {
    /// The genre that describes this song, for stats, history and mixes.
    var mainGenre: String? {
        MainGenre.pick(MainGenre.names(genres, first: genre))
    }

    func hasGenre(_ name: String) -> Bool { MainGenre.contains(genres, first: genre, name) }
}

extension Album {
    var mainGenre: String? {
        MainGenre.pick(MainGenre.names(genres, first: genre))
    }

    func hasGenre(_ name: String) -> Bool { MainGenre.contains(genres, first: genre, name) }
}
