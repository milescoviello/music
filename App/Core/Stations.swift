import Foundation

/// A station: a queue that never ends, topped up as it plays.
///
/// Plexamp gets its stations from the Plex server — Library Radio, Deep Cuts, Time
/// Travel, Random Album Radio, and one per decade, genre and mood — and its two Mix
/// Builders from the app. Navidrome has none of them, so each is assembled here from what
/// it does have: random songs by year or genre, album lists, play counts, similar songs.
/// The names are Plex's, and each subtitle says what it actually does.
enum Station: Codable, Hashable, Sendable, Identifiable {
    case library
    case deepCuts
    case timeTravel
    case randomAlbum
    /// The first year of the decade: 1990 for the 1990s.
    case decade(Int)
    case genre(String)
    /// Plexamp's Artist Mix Builder: these artists, and the ones like them.
    case artistMix(ids: [String], names: [String])
    /// Plexamp's Album Mix Builder: these albums, shuffled, and what goes with them.
    case albumMix(ids: [String], names: [String])
    /// Track, album or playlist radio: what is related to the seeds, drifting with what
    /// has played since — Plexamp's radios do not end, so neither do these.
    case radio(seedIDs: [String], title: String)
    /// One of the sonic model's tags as a station — "Chill", "Sad", "Party" — drawn from
    /// the tracks that sound most like it. Needs the sonic service.
    case mood(String)
    /// Plexamp's Sonic Adventure: a path from one track to another. Not endless — it
    /// arrives — so it is never topped up.
    case adventure(fromID: String, toID: String)

    var id: String {
        switch self {
        case .library: return "library"
        case .deepCuts: return "deepCuts"
        case .timeTravel: return "timeTravel"
        case .randomAlbum: return "randomAlbum"
        case let .decade(start): return "decade-\(start)"
        case let .genre(name): return "genre-\(name)"
        case let .artistMix(ids, _): return "artists-" + ids.joined(separator: ",")
        case let .albumMix(ids, _): return "albums-" + ids.joined(separator: ",")
        case let .adventure(from, to): return "adventure-\(from)-\(to)"
        case let .radio(seeds, title): return "radio-\(title)-" + seeds.joined(separator: ",")
        case let .mood(tag): return "mood-\(tag)"
        }
    }

    var title: String {
        switch self {
        case .library: return "Library Radio"
        case .deepCuts: return "Deep Cuts Radio"
        case .timeTravel: return "Time Travel Radio"
        case .randomAlbum: return "Random Album Radio"
        case let .decade(start): return "\(start)s Radio"
        case let .genre(name): return "\(name) Radio"
        case let .artistMix(_, names): return Self.mixTitle(names, fallback: "Artist Mix")
        case let .albumMix(_, names): return Self.mixTitle(names, fallback: "Album Mix")
        case .adventure: return "Sonic Adventure"
        case let .radio(_, title): return title
        case let .mood(tag): return "\(Self.moodName(tag)) Radio"
        }
    }

    var subtitle: String {
        switch self {
        case .library: return "Anything from your library, forever"
        case .deepCuts: return "The tracks you skip past, by the artists you play most"
        case .timeTravel: return "Your library from its oldest to its newest"
        case .randomAlbum: return "One whole album after another"
        case let .decade(start): return "Anything from \(start) to \(start + 9)"
        case let .genre(name): return "Anything tagged \(name)"
        case .artistMix: return "These artists, and the ones like them"
        case .albumMix: return "These albums, shuffled together"
        case .adventure: return "From one track to another"
        case .radio: return "Related tracks, for as long as you listen"
        case let .mood(tag): return "What sounds most \(Self.moodName(tag).lowercased())"
        }
    }

    var symbol: String {
        switch self {
        case .library: return "dot.radiowaves.left.and.right"
        case .deepCuts: return "waveform.path.ecg"
        case .timeTravel: return "clock.arrow.circlepath"
        case .randomAlbum: return "die.face.5"
        case .decade: return "calendar"
        case .genre: return "guitars"
        case .artistMix: return "person.2.wave.2"
        case .albumMix: return "square.stack.3d.up"
        case .adventure: return "point.topleft.down.to.point.bottomright.curvepath"
        case .radio: return "dot.radiowaves.left.and.right"
        case .mood: return "waveform.path"
        }
    }

    /// Whether it is topped up as it plays.
    var isEndless: Bool {
        if case .adventure = self { return false }
        return true
    }

    /// The model's tags are Last.fm's, in its spelling ("Mellow", "chillout"); this reads
    /// them as names.
    static func moodName(_ tag: String) -> String {
        tag.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// The tags that make good stations: moods and textures, not decades or genres (which
    /// have their own stations from the library's own tags).
    static let moodTags = [
        "chill", "Mellow", "happy", "sad", "party", "beautiful", "catchy", "sexy",
        "easy listening", "chillout", "acoustic", "instrumental", "ambient", "experimental",
    ]

    /// "Radiohead, Portishead & 2 more Mix".
    private static func mixTitle(_ names: [String], fallback: String) -> String {
        switch names.count {
        case 0: return fallback
        case 1: return "\(names[0]) Mix"
        case 2: return "\(names[0]) & \(names[1]) Mix"
        default: return "\(names[0]), \(names[1]) & \(names.count - 2) More"
        }
    }
}

/// The parts of the stations that are arithmetic rather than requests.
enum StationRules {
    /// A station is topped up when this few tracks are left after the current one.
    static let refillWhenRemaining = 5
    /// How many tracks one top-up adds.
    static let batchSize = 25

    static func needsRefill(_ queue: PlaybackQueue) -> Bool {
        guard let station = queue.station, station.isEndless else { return false }
        return queue.order.count - (queue.position + 1) <= refillWhenRemaining
    }

    /// Candidates that are not already in the queue, and not repeated among themselves.
    static func fresh(_ candidates: [Song], excluding queue: [Song]) -> [Song] {
        var seen = Set(queue.map(\.id))
        return candidates.filter { seen.insert($0.id).inserted }
    }

    /// Deep Cuts: the least-played first, never-played above all. Ties keep their order,
    /// which the caller has already shuffled.
    static func deepCuts(_ songs: [Song], limit: Int) -> [Song] {
        let ranked = songs.enumerated().sorted { lhs, rhs in
            let left = lhs.element.playCount ?? 0
            let right = rhs.element.playCount ?? 0
            return left == right ? lhs.offset < rhs.offset : left < right
        }
        return Array(ranked.prefix(limit).map(\.element))
    }

    /// The next span of years Time Travel plays: five years on from where the queue got
    /// to, back to the start once it passes the present.
    static func nextTimeTravelSpan(after year: Int?, earliest: Int, latest: Int) -> ClosedRange<Int> {
        var start = (year ?? earliest - 1) + 1
        if start > latest { start = earliest }
        return start...min(start + 4, latest)
    }

    /// Songs in the order of their year; those with no year cannot travel and are dropped.
    static func chronological(_ songs: [Song]) -> [Song] {
        songs.filter { ($0.year ?? 0) > 0 }.sorted { ($0.year ?? 0) < ($1.year ?? 0) }
    }

    /// Interleaves several lists one from each in turn, so a mix of four artists is not
    /// four artists one after another.
    static func interleave(_ lists: [[Song]]) -> [Song] {
        var result: [Song] = []
        var iterators = lists.map { $0.makeIterator() }
        var exhausted = false
        while !exhausted {
            exhausted = true
            for index in iterators.indices {
                if let song = iterators[index].next() {
                    result.append(song)
                    exhausted = false
                }
            }
        }
        return result
    }
}
