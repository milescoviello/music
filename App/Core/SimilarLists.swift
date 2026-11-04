import Foundation

/// Plexamp's three lists of tracks like one: Sonically Similar from the sonic analysis,
/// Related from Navidrome's agents, and Outside Your Comfort Zone (close in sound, by
/// other artists, unplayed first). Show Similar Tracks and the queue's Related tab, on
/// both apps.
enum SimilarKind: String, CaseIterable, Identifiable, Sendable {
    case sonic = "Sonically Similar"
    case related = "Related"
    case comfortZone = "Outside Your Comfort Zone"

    var id: String { rawValue }

    /// What Plexamp's Related tab heads each list with.
    var heading: String {
        switch self {
        case .sonic: return "Sonically Similar Tracks"
        case .related: return "Related Tracks"
        case .comfortZone: return "Outside Your Comfort Zone"
        }
    }

    var short: String {
        switch self {
        case .sonic: return "Similar"
        case .related: return "Related"
        case .comfortZone: return "Outside"
        }
    }

    func footer(_ song: Song) -> String {
        switch self {
        case .sonic: return "Tracks that sound most like this one, from the sonic analysis of your library."
        case .related: return "Tracks by artists your server considers similar to \(song.artist ?? "this one")."
        case .comfortZone: return "Related in sound but not close, by other artists — the ones you haven't played first."
        }
    }
}

extension AppState {
    /// The lists that have anything in them, in Plexamp's order. Never the song itself,
    /// nor its copy in the other library: Similar Tracks listed the playing song's twin
    /// as the most like it.
    func similarLists(to song: Song, limit: Int = 50) async -> [(kind: SimilarKind, songs: [Song])] {
        let client = client
        async let sonicList = sonic.similarSongs(to: song, limit: limit)
        async let distant = sonic.distantSongs(from: song, limit: limit)
        async let related = try? client.similarSongs(toSongID: song.id, count: limit)
        let results: [SimilarKind: [Song]] = [
            .sonic: await sonicList ?? [],
            .comfortZone: await distant ?? [],
            .related: await related ?? [],
        ]
        return SimilarKind.allCases.compactMap { kind in
            let songs = (results[kind] ?? []).filter { !$0.isSameRecording(as: song) }
            return songs.isEmpty ? nil : (kind, songs)
        }
    }
}
