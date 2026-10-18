import Foundation

/// What Plexamp's Autoplay can put on when the queue runs out. Raw values are Plexamp's own
/// ids, so the two stored settings mean the same thing they do there.
enum AutoplayChoice: Int, Codable, CaseIterable, Identifiable, Sendable {
    case silence = 0
    case previousAlbum = 1
    case nextAlbum = 2
    case similarAlbum = 3
    case artistMix = 4
    case artistRadio = 5
    case similarArtists = 7
    case decade = 9
    case libraryRadio = 10
    case trackRadio = 11

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .silence: return "Silence"
        case .previousAlbum: return "Previous Album"
        case .nextAlbum: return "Next Album"
        case .similarAlbum: return "Similar Album"
        case .artistMix: return "Artist Mix"
        case .artistRadio: return "Artist Radio"
        case .similarArtists: return "Similar Artists"
        case .decade: return "Decade"
        case .libraryRadio: return "Library Radio"
        case .trackRadio: return "Track Radio"
        }
    }

    var symbol: String {
        switch self {
        case .silence: return "moon.zzz"
        case .previousAlbum: return "backward.end"
        case .nextAlbum: return "forward.end"
        case .similarAlbum: return "square.stack"
        case .artistMix: return "person.wave.2"
        case .artistRadio, .trackRadio, .libraryRadio: return "dot.radiowaves.left.and.right"
        case .similarArtists: return "person.2"
        case .decade: return "calendar"
        }
    }

    /// Plexamp adds 20 tracks of a radio and 30 of anything else.
    var trackCount: Int {
        switch self {
        case .artistRadio, .trackRadio, .libraryRadio: return 20
        default: return 30
        }
    }

    /// Whether it plays its tracks in their own order — an album — rather than shuffled.
    var isAlbum: Bool {
        [.previousAlbum, .nextAlbum, .similarAlbum].contains(self)
    }
}

/// Plexamp's Autoplay rules, Foundation-only so they are tested.
enum AutoplayRules {
    /// Autoplay is only offered with fewer than this many tracks up next.
    static let maximumUpNext = 30

    /// Repeat off, a short enough queue, and not something that keeps itself going — a
    /// station or a mix extends on its own and must not be capped by a carousel.
    static func isActive(repeatMode: RepeatMode, upNextCount: Int, isSelfExtending: Bool) -> Bool {
        repeatMode == .off && upNextCount < maximumUpNext && !isSelfExtending
    }

    /// Plexamp's test for "the queue ends with an album": its last two tracks share one.
    static func endsWithAlbum(_ queue: PlaybackQueue) -> Bool {
        let tail = queue.order.suffix(2).compactMap { queue.tracks.indices.contains($0) ? queue.tracks[$0] : nil }
        guard tail.count == 2, let album = tail[0].albumId else { return false }
        return tail[1].albumId == album
    }

    /// The carousel, in Plexamp's order. After an album there are album-shaped things to
    /// go to next — the next album or the previous one, whichever the Album Direction
    /// setting says; otherwise only the mixes.
    static func choices(endedWithAlbum: Bool, albumDirection: AutoplayChoice = .nextAlbum) -> [AutoplayChoice] {
        let neighbour: AutoplayChoice = albumDirection == .previousAlbum ? .previousAlbum : .nextAlbum
        return endedWithAlbum
            ? [.silence, neighbour, .similarAlbum, .artistMix, .artistRadio,
               .trackRadio, .similarArtists, .decade, .libraryRadio]
            : [.silence, .similarArtists, .trackRadio, .decade, .libraryRadio]
    }

    /// Plexamp's defaults: the album in the chosen direction after an album, similar
    /// artists otherwise.
    static func defaultChoice(endedWithAlbum: Bool, albumDirection: AutoplayChoice = .nextAlbum) -> AutoplayChoice {
        endedWithAlbum ? (albumDirection == .previousAlbum ? .previousAlbum : .nextAlbum) : .similarArtists
    }

    /// The remembered choice if it is on offer, else the first that is not silence —
    /// Plexamp's fallback, so a choice that cannot be made here (no next album) does not
    /// quietly turn into stopping.
    static func selection(preferred: AutoplayChoice, available: [AutoplayChoice]) -> AutoplayChoice? {
        if available.contains(preferred) { return preferred }
        return available.first { $0 != .silence }
    }

    /// The album after (or before) `albumID` in an artist's discography, oldest first by
    /// year then name. Nil at either end.
    static func neighbour(of albumID: String, in albums: [Album], direction: AutoplayChoice) -> Album? {
        let ordered = albums.sorted {
            ($0.year ?? 0, $0.name.lowercased()) < ($1.year ?? 0, $1.name.lowercased())
        }
        guard let index = ordered.firstIndex(where: { $0.id == albumID }) else { return nil }
        let target = direction == .previousAlbum ? index - 1 : index + 1
        return ordered.indices.contains(target) ? ordered[target] : nil
    }

    /// 1994 → 1990.
    static func decadeStart(of year: Int) -> Int {
        year - year % 10
    }
}
