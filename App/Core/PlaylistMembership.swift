import Foundation

/// How much of some songs a playlist already has: what Add to Playlist says beside each
/// playlist, and what it leaves out when adding.
///
/// The same recording counts, not only the same file. The two libraries hold most songs
/// twice under different ids, so a playlist with the "My Music" copy already has the song,
/// and adding the "Music" one as well would play it twice. A recording is its title, artist
/// and album, case and outer spaces aside; the album keeps two songs called "Intro" by one
/// artist apart.
struct PlaylistMembership: Equatable, Sendable {
    /// Of the songs asked about, how many the playlist has.
    let present: Int
    /// The songs asked about, each recording once.
    let total: Int

    init(of songs: [Song], in entries: [Song]) {
        let asked = Self.missing(songs, from: [])
        total = asked.count
        present = total - Self.missing(asked, from: entries).count
    }

    /// Nothing to add: the row is shown ticked and cannot be chosen.
    var hasAll: Bool { total > 0 && present == total }

    /// What the row says, or nil when the playlist has none of them.
    var summary: String? {
        guard present > 0 else { return nil }
        if total == 1 { return "Already added" }
        if present == total { return "All \(total) already added" }
        return "\(present) of \(total) already added"
    }

    /// `songs` less those the playlist has and less repeats among themselves, in order.
    static func missing(_ songs: [Song], from entries: [Song]) -> [Song] {
        var ids = Set(entries.map(\.id))
        var recordings = Set(entries.map(recording))
        return songs.filter { song in
            guard ids.insert(song.id).inserted else { return false }
            return recordings.insert(recording(song)).inserted
        }
    }

    static func recording(_ song: Song) -> String {
        [song.title, song.artist ?? "", song.album ?? ""]
            .map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: "\u{1F}")
    }
}

extension Song {
    /// This song, or the same recording in the other library: what a list shows as playing.
    /// Most songs are there twice under different ids, and a row showing the copy not
    /// playing stayed unlit while its song played. A live version on another album is a
    /// different recording, and stays unlit.
    func isSameRecording(as other: Song?) -> Bool {
        guard let other else { return false }
        if id == other.id { return true }
        // Two tracks of one album with one name ("Allegro", "Interlude") are not copies.
        if let album = albumId, album == other.albumId { return false }
        return PlaylistMembership.recording(self) == PlaylistMembership.recording(other)
    }
}
