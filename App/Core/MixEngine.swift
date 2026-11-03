import Foundation

/// The arithmetic behind the daily mixes.
///
/// Foundation-only and compiled into the test package, because "why is this in my mix"
/// has to have an exact answer, and because a mix that reshuffles every time the screen
/// redraws feels broken. Everything here is deterministic: the same history and the same
/// day give the same mix, byte for byte.
enum MixEngine {
    /// One past play, reduced to what a mix needs to know about it.
    struct Sample: Sendable {
        let songID: String
        let artist: String
        var genre: String?
        let at: Date
        /// Usually one play. A cold start has no play *events* — only the server's
        /// per-track counts, which reach back through the Plex import — so those rows
        /// arrive as a single sample weighted by how often the track was played.
        var weight: Double = 1
    }

    /// Affinity halves every 30 days.
    ///
    /// So a play last week counts about 1.2× one from a month ago and 8× one from three
    /// months ago: the mixes follow what someone is into now rather than settling
    /// permanently on an all-time favourite.
    static let halfLifeDays = 30.0

    /// Plays per artist per day that count towards affinity. An album on repeat all
    /// afternoon is one enthusiasm, not fourteen; uncapped, a single evening owns the
    /// mixes for the next month.
    static let dailyCap = 5.0

    static func artistScores(
        _ samples: [Sample],
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [String: Double] {
        scores(samples, now: now, calendar: calendar) { $0.artist }
    }

    // MARK: - Heavy Rotation

    /// One copy's plays, as the server counts them.
    struct Counted: Sendable {
        let id: String
        let title: String
        let artist: String?
        let plays: Int
        let lastPlayed: Date?
    }

    /// A recording someone plays, with every copy of it that was found.
    struct Played: Sendable {
        /// Most-played copy first. The library has most songs twice, and each copy keeps
        /// its own count, so "Laputa" can be 70 plays here and 65 there.
        var ids: [String]
        var title: String
        var artist: String?
        var plays: Int
        var lastPlayed: Date?
        var score: Double

        var identity: String { MixEngine.identity(title: title, artist: artist) }
    }

    /// What someone plays most lately, best first, one entry per recording.
    ///
    /// Heavy Rotation used to be the server's top songs *by* the most-played artists:
    /// Last.fm's chart for each, matched to the library, so it was full of songs never
    /// once played, and every extension was mostly radio. This is the songs themselves.
    ///
    /// Two signals, added. The server's counts reach back through every device and the
    /// Plex import, but only know when a song was last played, so they count
    /// logarithmically and fade with that date: 135 plays two months ago still ranks, and
    /// does not drown out this week. The phone's own log knows each play, so a song on
    /// repeat this month counts every day it was played, up to `dailyCap` a day, fading
    /// with the same half-life as the artist scores. Early skips, from `SkipMemory`, count
    /// against a song at two points each.
    static func heavyRotation(
        counted: [Counted],
        plays samples: [Sample],
        skipped: [String: Double] = [:],
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [Played] {
        var order: [String] = []
        var groups: [String: [Counted]] = [:]
        var seen: Set<String> = []
        for copy in counted where copy.plays > 0 && seen.insert(copy.id).inserted {
            let key = identity(title: copy.title, artist: copy.artist)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(copy)
        }
        var recordingOf: [String: String] = [:]
        for (key, copies) in groups {
            for copy in copies { recordingOf[copy.id] = key }
        }
        let local = scores(samples, now: now, calendar: calendar) { recordingOf[$0.songID] }

        let today = calendar.startOfDay(for: now)
        func fade(_ date: Date?) -> Double {
            // A count with no date is an old import: weighed as half a year ago.
            guard let date else { return pow(0.5, 180 / halfLifeDays) }
            let elapsed = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: today).day ?? 0
            return pow(0.5, Double(max(0, elapsed)) / halfLifeDays)
        }

        var played: [(offset: Int, entry: Played)] = []
        for (offset, key) in order.enumerated() {
            guard let copies = groups[key]?.sorted(by: { $0.plays > $1.plays }), let first = copies.first else { continue }
            let plays = copies.reduce(0) { $0 + $1.plays }
            let last = copies.compactMap(\.lastPlayed).max()
            played.append((offset, Played(
                ids: copies.map(\.id),
                title: first.title,
                artist: first.artist,
                plays: plays,
                lastPlayed: last,
                score: log2(1 + Double(plays)) * fade(last) + (local[key] ?? 0) - 2 * (skipped[key] ?? 0)
            )))
        }
        return played
            .sorted { $0.entry.score != $1.entry.score ? $0.entry.score > $1.entry.score : $0.offset < $1.offset }
            .map(\.entry)
    }

    /// A day's pick from the ranking: shuffled among the best `reach` not yet in a mix,
    /// so the mix changes from day to day but never reaches far down, and each extension
    /// carries on from where the last one stopped rather than starting again at the top.
    static func pickPlayed(
        _ ranked: [Played],
        limit: Int,
        reach: Int,
        perArtist: Int,
        excludingIDs used: Set<String>,
        excludingIdentities identities: Set<String>,
        using generator: inout DayRandom
    ) -> [Played] {
        let fresh = ranked.filter { entry in
            !identities.contains(entry.identity) && !entry.ids.contains(where: used.contains)
        }
        var perArtistCount: [String: Int] = [:]
        var chosen: [Played] = []
        for entry in fresh.prefix(reach).shuffled(using: &generator) {
            guard chosen.count < limit else { break }
            let artist = entry.artist ?? ""
            guard perArtistCount[artist, default: 0] < perArtist else { continue }
            perArtistCount[artist, default: 0] += 1
            chosen.append(entry)
        }
        return chosen
    }

    // MARK: - Radio, to taste

    /// An artist as the taste scores key it.
    static func artistKey(_ artist: String?) -> String {
        (artist ?? "").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Radio for the mixes: among the nearest-sounding candidates, artists already played
    /// first, and no more than `unknownShare` of the batch from artists never played.
    ///
    /// The server's similar songs come from Last.fm listeners, which is why one artist's
    /// radio was right and the next was full of things never listened to; the sound
    /// analysis finds what sounds alike, and this keeps it near what is actually played.
    static func pickRadio(
        _ candidates: [Song],
        affinity: [String: Double],
        limit: Int,
        perArtist: Int,
        unknownShare: Double = 1.0 / 3,
        excluding used: Set<String>,
        usedIdentities: Set<String>,
        using generator: inout DayRandom
    ) -> [Song] {
        var seen = usedIdentities
        var nearest: [Song] = []
        for song in candidates where !used.contains(song.id) && seen.insert(identity(song)).inserted {
            nearest.append(song)
            if nearest.count >= limit * 3 { break }
        }
        let isKnown = { (song: Song) in (affinity[artistKey(song.artist)] ?? 0) > 0 }
        let known = nearest.filter(isKnown).shuffled(using: &generator)
        let unknown = nearest.filter { !isKnown($0) }.shuffled(using: &generator)
        let unknownCap = Int((Double(limit) * unknownShare).rounded(.down))

        var perArtistCount: [String: Int] = [:]
        var chosen: [Song] = []
        var unknownTaken = 0
        for song in known + unknown {
            guard chosen.count < limit else { break }
            let artist = artistKey(song.artist)
            guard perArtistCount[artist, default: 0] < perArtist else { continue }
            if !isKnown(song) {
                guard unknownTaken < unknownCap else { continue }
                unknownTaken += 1
            }
            perArtistCount[artist, default: 0] += 1
            chosen.append(song)
        }
        return chosen.shuffled(using: &generator)
    }

    /// How much each artist is played, by `artistKey`: the play log's scores and the
    /// ranked songs', less their early skips.
    static func affinity(
        samples: [Sample],
        played: [Played],
        skipped: [String: Double],
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [String: Double] {
        var totals: [String: Double] = [:]
        for (artist, score) in artistScores(samples, now: now, calendar: calendar) {
            totals[artistKey(artist), default: 0] += score
        }
        for entry in played { totals[artistKey(entry.artist), default: 0] += entry.score }
        for (recording, penalty) in skipped {
            let artist = String(recording.split(separator: "|", maxSplits: 1).first ?? "")
            totals[artist, default: 0] -= penalty
        }
        return totals
    }

    static func genreScores(
        _ samples: [Sample],
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [String: Double] {
        scores(samples, now: now, calendar: calendar) { $0.genre }
    }

    /// Half-life weighted totals, capped per key per day.
    private static func scores(
        _ samples: [Sample],
        now: Date,
        calendar: Calendar,
        by key: (Sample) -> String?
    ) -> [String: Double] {
        // Summed per day first, so the cap applies to a day's listening rather than to
        // the whole history.
        var daily: [String: [Date: Double]] = [:]
        for sample in samples {
            guard let name = key(sample), !name.isEmpty else { continue }
            let day = calendar.startOfDay(for: sample.at)
            daily[name, default: [:]][day, default: 0] += sample.weight
        }

        let today = calendar.startOfDay(for: now)
        var totals: [String: Double] = [:]
        for (name, days) in daily {
            var total = 0.0
            for (day, plays) in days {
                let elapsed = calendar.dateComponents([.day], from: day, to: today).day ?? 0
                // A play stamped in the future (clock skew, an import) counts as today
                // rather than being weighted up beyond 1.
                let decay = pow(0.5, Double(max(0, elapsed)) / halfLifeDays)
                total += min(plays, dailyCap) * decay
            }
            totals[name] = total
        }
        return totals
    }

    /// Highest score first. Ties broken by name, because dictionary order is not stable
    /// between runs and a mix that reorders itself for no reason looks like a bug.
    static func ranked(_ scores: [String: Double], limit: Int = .max) -> [String] {
        scores
            .sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .prefix(limit)
            .map(\.key)
    }

    /// Songs played in the last `days` days.
    ///
    /// Excluded from Heavy Rotation: a mix built from a favourite artist is worth having,
    /// a mix of the six tracks already played this morning is not.
    static func songIDs(_ samples: [Sample], playedWithin days: Int, now: Date = .now) -> Set<String> {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        return Set(samples.filter { $0.at >= cutoff }.map(\.songID))
    }

    /// Deterministic randomness, keyed on the day.
    ///
    /// `shuffled()` and `randomElement()` differ every run, so without this the mixes
    /// would change on every redraw and could not be tested at all. Salted per mix so the
    /// three of them do not make identical choices out of overlapping candidates.
    struct DayRandom: RandomNumberGenerator {
        private var state: UInt64

        init(day: Date, salt: UInt64 = 0, calendar: Calendar = .current) {
            let start = calendar.startOfDay(for: day).timeIntervalSince1970
            state = UInt64(bitPattern: Int64(start)) ^ (salt &* 0x9E37_79B9_7F4A_7C15)
            // A zero state would emit zeros forever, which is a real possibility here
            // since the seed is arithmetic on a date rather than random bits.
            if state == 0 { state = 0x9E37_79B9_7F4A_7C15 }
        }

        /// splitmix64: three lines, well-distributed, and identical on every platform —
        /// which matters because a test asserts on the numbers it produces.
        mutating func next() -> UInt64 {
            state = state &+ 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// The identity two copies of the same recording share.
    ///
    /// This library has two overlapping folders: roughly 40% of tracks have a twin, and
    /// 4,957 title-and-artist groups are duplicated. Without collapsing them a mix shows
    /// the same song twice, which reads as carelessness rather than as a library problem.
    static func identity(_ song: Song) -> String {
        identity(title: song.title, artist: song.artist)
    }

    static func identity(title: String, artist: String?) -> String {
        let title = title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = (artist ?? "").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(artist)|\(title)"
    }

    /// Pick up to `limit` songs, at most `perArtist` by any one artist, skipping anything
    /// an earlier mix already used and any second copy of the same recording.
    ///
    /// Shuffled with the day's generator rather than taken in order, so Heavy Rotation is
    /// not the same three tracks off the top of each artist every single day.
    static func choose(
        from candidates: [Song],
        limit: Int,
        perArtist: Int,
        excluding used: Set<String>,
        usedIdentities: Set<String> = [],
        using generator: inout DayRandom
    ) -> [Song] {
        var perArtistCount: [String: Int] = [:]
        var identities = usedIdentities
        var chosen: [Song] = []

        for song in candidates.shuffled(using: &generator) {
            guard chosen.count < limit else { break }
            guard !used.contains(song.id) else { continue }

            let identity = identity(song)
            guard !identities.contains(identity) else { continue }

            let artist = song.artist ?? ""
            guard perArtistCount[artist, default: 0] < perArtist else { continue }

            perArtistCount[artist, default: 0] += 1
            identities.insert(identity)
            chosen.append(song)
        }
        return chosen
    }
}
