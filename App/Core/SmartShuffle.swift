import Foundation

/// Shuffle, the smart way, offered beside the plain one, which stays as random as ever.
///
/// Still random, only weighted: a song not heard for a while is likelier to come early,
/// one skipped early lately likelier to come late, and the same artist is not played twice
/// running when anything else is near. A weighted random order (each song's key is a
/// uniform draw to the power of one over its weight, highest first), then a pass that
/// pulls the next different artist forward from a few places ahead.
enum SmartShuffle {
    /// How often to weigh a song not played in the log at all, as if this many days ago.
    static let unplayedDays = 60.0

    static func weight(daysSincePlayed days: Double?, skipPenalty: Double) -> Double {
        let freshness = min(1 + (days ?? unplayedDays) / 14, 5)
        return freshness * max(0.25, 1 - 0.4 * skipPenalty)
    }

    /// The order to play `indices` of `tracks` in.
    static func order<G: RandomNumberGenerator>(
        _ indices: [Int],
        of tracks: [Song],
        lastPlayed: [String: Date],
        skipped: [String: Double],
        now: Date = .now,
        using generator: inout G
    ) -> [Int] {
        let keyed: [(index: Int, key: Double)] = indices.map { index in
            let identity = MixEngine.identity(tracks[index])
            let days = lastPlayed[identity].map { max(0, now.timeIntervalSince($0) / 86_400) }
            let weight = weight(daysSincePlayed: days, skipPenalty: skipped[identity] ?? 0)
            let draw = Double.random(in: Double.ulpOfOne..<1, using: &generator)
            return (index, pow(draw, 1 / weight))
        }
        var pending = keyed.sorted { $0.key > $1.key }.map(\.index)

        // The same artist twice running only when nothing else is within reach.
        let lookahead = 8
        var result: [Int] = []
        result.reserveCapacity(pending.count)
        while !pending.isEmpty {
            let last = result.last.map { MixEngine.artistKey(tracks[$0].artist) }
            let pick = pending.prefix(lookahead).firstIndex { MixEngine.artistKey(tracks[$0].artist) != last } ?? 0
            result.append(pending.remove(at: pick))
        }
        return result
    }
}

/// A radio that is not the same songs every time from the same seed. Sonic's nearest
/// neighbours to a song are always the same list, so Track Radio after one song, and a
/// station started from it, played the same twenty each time. A radio now asks for a few
/// times more than it plays and draws from them -- the nearest likeliest, the further ones
/// still in with a chance -- in an order that starts near the seed without always starting
/// on the same song.
enum RadioVariety {
    /// How many to ask for, to draw `count` from.
    static func poolSize(for count: Int) -> Int {
        min(max(count, 1) * 4, 500)
    }

    /// `count` of `ranked`, nearest first in the input, drawn at random and weighted by
    /// nearness: a weighted random order (a uniform draw to the power of one over each
    /// weight, highest first), cut to `count`, then put back roughly in nearness order,
    /// each one moved by up to half the list.
    static func draw<T, G: RandomNumberGenerator>(_ ranked: [T], count: Int, using generator: inout G) -> [T] {
        guard count > 0, !ranked.isEmpty else { return [] }
        let spread = Double(count) * 1.5
        let keyed = ranked.indices.map { rank -> (rank: Int, key: Double) in
            let weight = exp(-Double(rank) / spread)
            let draw = Double.random(in: Double.leastNonzeroMagnitude..<1, using: &generator)
            return (rank, pow(draw, 1 / weight))
        }
        let chosen = keyed.sorted { $0.key > $1.key }.prefix(count)
        let jitter = Double(count) / 2
        return chosen
            .map { (rank: $0.rank, place: Double($0.rank) + Double.random(in: 0...jitter, using: &generator)) }
            .sorted { $0.place < $1.place }
            .map { ranked[$0.rank] }
    }
}
