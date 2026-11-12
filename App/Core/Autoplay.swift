import Foundation

/// What Plexamp's Autoplay can put on when the queue runs out. Raw values are Plexamp's own
/// ids, so the two stored settings mean the same thing they do there -- except Playlist
/// Radio, which Plexamp does not have, numbered well clear of them.
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
    case playlistRadio = 100

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
        case .playlistRadio: return "Playlist Radio"
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
        case .playlistRadio: return "music.note.list"
        }
    }

    /// Plexamp adds 20 tracks of a radio and 30 of anything else.
    var trackCount: Int {
        switch self {
        case .artistRadio, .trackRadio, .libraryRadio, .playlistRadio: return 20
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
    /// setting says; otherwise only the mixes. Playlist Radio is offered only for a queue
    /// with enough in it (`PlaylistRadio.pool`).
    static func choices(endedWithAlbum: Bool, albumDirection: AutoplayChoice = .nextAlbum) -> [AutoplayChoice] {
        let neighbour: AutoplayChoice = albumDirection == .previousAlbum ? .previousAlbum : .nextAlbum
        return endedWithAlbum
            ? [.silence, neighbour, .similarAlbum, .artistMix, .artistRadio,
               .trackRadio, .playlistRadio, .similarArtists, .decade, .libraryRadio]
            : [.silence, .playlistRadio, .similarArtists, .trackRadio, .decade, .libraryRadio]
    }

    /// Plexamp's defaults: the album in the chosen direction after an album, similar
    /// artists otherwise.
    static func defaultChoice(endedWithAlbum: Bool, albumDirection: AutoplayChoice = .nextAlbum) -> AutoplayChoice {
        endedWithAlbum ? (albumDirection == .previousAlbum ? .previousAlbum : .nextAlbum) : .similarArtists
    }

    /// The remembered choice if it is on offer, else the first that is not silence —
    /// Plexamp's fallback, so a choice that cannot be made here (no next album) does not
    /// quietly turn into stopping. Playlist Radio, not on offer for a queue of a song or
    /// two, falls back to the radio nearest it: Track Radio.
    static func selection(preferred: AutoplayChoice, available: [AutoplayChoice]) -> AutoplayChoice? {
        if available.contains(preferred) { return preferred }
        if preferred == .playlistRadio, available.contains(.trackRadio) { return .trackRadio }
        return available.first { $0 != .silence }
    }

    /// What an option's songs add: those not already in the queue and not skipped early
    /// lately -- unless it is an album, which is kept whole -- up to its count.
    ///
    /// `recent`, the songs Autoplay itself added lately (`AutoplayMemory`), go last rather
    /// than not at all: a radio around the same few songs draws from the same pool, and
    /// Autoplay played the same twenty every evening. Held back, not banned, so a small
    /// pool still fills its count before the option is given up for the next.
    static func fresh(
        _ songs: [Song], queued: Set<String>, avoided: Set<String>, recent: Set<String> = [], limit: Int
    ) -> [Song] {
        var seen = queued
        var kept: [Song] = []
        var heldBack: [Song] = []
        for song in songs where kept.count < limit && !avoided.contains(MixEngine.identity(song)) {
            guard seen.insert(song.id).inserted else { continue }
            if recent.contains(MixEngine.identity(song)) {
                heldBack.append(song)
            } else {
                kept.append(song)
            }
        }
        return kept + heldBack.prefix(max(0, limit - kept.count))
    }

    /// What to try, in order, when the queue runs out: the selection, then every other
    /// choice on offer, then Library Radio, which always has something. Autoplay used to
    /// try the selection alone, so a choice that came back empty -- no next album, a radio
    /// of songs already queued, a failed request -- stopped the music. Silence, chosen,
    /// is the one way to stop, and is honoured.
    static func attempts(selected: AutoplayChoice?, available: [AutoplayChoice]) -> [AutoplayChoice] {
        if selected == .silence { return [] }
        var order: [AutoplayChoice] = []
        for choice in [selected].compactMap({ $0 }) + available + [.libraryRadio]
        where choice != .silence && !order.contains(choice) {
            order.append(choice)
        }
        return order
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

/// Playlist Radio: what comes after a playlist, from the whole of it rather than its last
/// song. Each time, a few of its songs are drawn -- the later in the play order the
/// likelier, so where it ended counts most -- and a radio around each is taken in turn.
///
/// Around each song separately, not around all of them at once: the sonic service blends
/// several seeds into their average sound, and the average of a playlist that is half one
/// thing and half another sounds like neither half.
enum PlaylistRadio {
    /// Fewer songs than this, and it would be Track Radio under another name.
    static let minimumSongs = 4
    /// The songs a radio is taken around, each time.
    static let seedCount = 5
    /// How much likelier the last song in the play order is to be drawn than the first.
    static let recentWeight = 3.0
    /// Songs asked for around each seed: a share of the 20, with room for the ones two
    /// seeds share and the ones already queued.
    static let perSeed = 8

    /// What the seeds are drawn from: the queue as it was started -- the playlist, not
    /// what was added to it after, Autoplay's own songs among them -- in play order, one
    /// copy of each recording. Nil with too few songs, or when they are one album, which
    /// has the album cards.
    static func pool(_ queue: PlaybackQueue) -> [Song]? {
        let base = queue.baseCount ?? queue.tracks.count
        var seen: Set<String> = []
        var songs: [Song] = []
        for index in queue.order where index < base && queue.tracks.indices.contains(index) {
            let song = queue.tracks[index]
            guard seen.insert(MixEngine.identity(song)).inserted else { continue }
            songs.append(song)
        }
        guard songs.count >= minimumSongs, Set(songs.map { $0.albumId ?? $0.id }).count > 1 else { return nil }
        return songs
    }

    /// `count` of the pool, none twice, drawn with the later ones likelier, and the most
    /// recent first. All of it, most recent first, when it has no more than `count`.
    static func seeds<G: RandomNumberGenerator>(
        from pool: [Song],
        count: Int = seedCount,
        using generator: inout G
    ) -> [Song] {
        guard pool.count > count else { return pool.reversed() }
        let last = Double(pool.count - 1)
        // Weighted sampling without replacement (Efraimidis and Spirakis): each song gets
        // a key u^(1/weight), and the largest keys win.
        let keyed = pool.indices.map { index -> (key: Double, index: Int) in
            let weight = 1 + (recentWeight - 1) * Double(index) / last
            let u = Double.random(in: Double.leastNonzeroMagnitude..<1, using: &generator)
            return (pow(u, 1 / weight), index)
        }
        return keyed.sorted { $0.key > $1.key }
            .prefix(count)
            .map(\.index)
            .sorted(by: >)
            .map { pool[$0] }
    }

    /// One from each seed's radio in turn, the first seed's first, so every part of the
    /// playlist is heard from early on. Nothing twice, by id or by recording.
    static func interleave(_ radios: [[Song]], limit: Int) -> [Song] {
        var ids: Set<String> = []
        var recordings: Set<String> = []
        var result: [Song] = []
        let longest = radios.map(\.count).max() ?? 0
        for row in 0..<longest {
            for radio in radios where row < radio.count {
                guard result.count < limit else { return result }
                let song = radio[row]
                guard !ids.contains(song.id), recordings.insert(MixEngine.identity(song)).inserted else { continue }
                ids.insert(song.id)
                result.append(song)
            }
        }
        return result
    }
}

/// The songs Autoplay added, and when, for two weeks: what `AutoplayRules.fresh` holds back.
/// By recording (`MixEngine.identity`), so the other library's copy of a song is the same
/// song. Kept in the defaults; a few hundred entries at most.
struct AutoplayMemory: Equatable, Sendable {
    static let span: TimeInterval = 14 * 86_400

    /// Recording identity to when Autoplay last added it, seconds since 1970.
    private(set) var added: [String: Double]

    init(added: [String: Double] = [:]) {
        self.added = added
    }

    mutating func note(_ songs: [Song], at date: Date = .now) {
        let time = date.timeIntervalSince1970
        for song in songs { added[MixEngine.identity(song)] = time }
        forget(before: date)
    }

    func recent(at date: Date = .now) -> Set<String> {
        let since = date.timeIntervalSince1970 - Self.span
        return Set(added.filter { $0.value >= since }.keys)
    }

    mutating func forget(before date: Date) {
        let since = date.timeIntervalSince1970 - Self.span
        added = added.filter { $0.value >= since }
    }
}

