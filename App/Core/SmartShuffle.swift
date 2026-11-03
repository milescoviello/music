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
