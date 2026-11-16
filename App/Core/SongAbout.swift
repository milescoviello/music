import Foundation

/// What a song is about, for the About sheet: a few sentences written ahead of time, background quoted from the
/// song's Genius and Wikipedia pages, and Genius's notes on lines of the lyrics. From the companion service
/// (`server/sonic/sonic/about.py`), which looks a song up the first time it is asked about.
struct SongAbout: Decodable, Equatable, Sendable {
    struct Summary: Decodable, Equatable, Sendable {
        var text: String
        /// "sources" when it rests on the background quoted below it; "lyrics" when there was nothing to go on
        /// but the words, which the sheet says.
        var basis: String

        var isReadingOfLyrics: Bool { basis == "lyrics" }
    }

    /// A passage quoted from one of the song's pages: Genius's About, or a section of its Wikipedia article.
    struct Section: Decodable, Equatable, Sendable, Identifiable {
        var source: String
        var heading: String
        var text: String
        var url: String?

        var id: String { "\(source)/\(heading)" }
    }

    /// A Genius note on a fragment of the lyrics, mostly a listener's.
    struct Note: Decodable, Equatable, Sendable, Identifiable {
        var fragment: String
        var text: String
        var url: String?
        var reviewed: Bool?

        var id: String { "\(fragment)\u{1f}\(text.prefix(40))" }
    }

    struct Link: Decodable, Equatable, Sendable, Identifiable {
        var name: String
        var url: String?

        var id: String { name }
    }

    var id: String
    var title: String?
    var artist: String?
    var album: String?
    var summary: Summary?
    var released: String?
    var writers: [String]
    var sections: [Section]
    var notes: [Note]
    var links: [Link]
    /// Genius and Wikipedia could not be reached when the service looked; it tries again within the hour.
    var unavailable: Bool

    var isEmpty: Bool { summary == nil && sections.isEmpty && notes.isEmpty }

    /// "1999 · Anthony Kiedis, Flea": when it came out and who wrote it, for under the title.
    var facts: String? {
        let year = released.flatMap { date in date.range(of: #"\d{4}"#, options: .regularExpression).map { String(date[$0]) } }
        let parts = [year, writers.isEmpty ? nil : "Written by " + writers.prefix(4).joined(separator: ", ")
            + (writers.count > 4 ? " and \(writers.count - 4) more" : "")].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, artist, album, summary, released, writers, sections, notes, links, unavailable
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        artist = try c.decodeIfPresent(String.self, forKey: .artist)
        album = try c.decodeIfPresent(String.self, forKey: .album)
        summary = try c.decodeIfPresent(Summary.self, forKey: .summary)
        released = try c.decodeIfPresent(String.self, forKey: .released)
        writers = try c.decodeIfPresent([String].self, forKey: .writers) ?? []
        sections = try c.decodeIfPresent([Section].self, forKey: .sections) ?? []
        notes = try c.decodeIfPresent([Note].self, forKey: .notes) ?? []
        links = try c.decodeIfPresent([Link].self, forKey: .links) ?? []
        unavailable = try c.decodeIfPresent(Bool.self, forKey: .unavailable) ?? false
    }
}
