import Foundation

/// Songs skipped by hand soon after they start, so the mixes stop serving them.
///
/// A skip only counts against a song when it was playing, early (the first 30 seconds,
/// or the first half of something shorter than a minute) and by hand. Skipping one that
/// would not load is the network's fault, not the song's. Each skip fades with the same
/// 30-day half-life as everything else in the mixes, and a song played through since
/// its last skip is forgiven: a mood is not a verdict.
enum SkipMemory {
    struct Skip: Codable, Sendable, Equatable {
        let songID: String
        let title: String
        let artist: String
        let at: Date
        /// Seconds into the song.
        let position: Double
    }

    /// Two recent skips with no full play since: out of the mixes and radio.
    static let avoidAt = 1.5

    static func isEarly(position: Double, duration: Double) -> Bool {
        guard position < 30 else { return false }
        return duration <= 0 || duration >= 60 || position < duration / 2
    }

    /// Per recording (`MixEngine.identity`), the faded skips since its last full play.
    static func penalties(
        skips: [Skip],
        plays: [(identity: String, at: Date)],
        now: Date = .now
    ) -> [String: Double] {
        var lastPlay: [String: Date] = [:]
        for play in plays where play.at > (lastPlay[play.identity] ?? .distantPast) {
            lastPlay[play.identity] = play.at
        }
        var totals: [String: Double] = [:]
        for skip in skips {
            let key = MixEngine.identity(title: skip.title, artist: skip.artist)
            if let played = lastPlay[key], played > skip.at { continue }
            let days = max(0, now.timeIntervalSince(skip.at) / 86_400)
            totals[key, default: 0] += pow(0.5, days / MixEngine.halfLifeDays)
        }
        return totals
    }

    /// The recordings to leave out.
    static func avoided(_ penalties: [String: Double]) -> Set<String> {
        Set(penalties.filter { $0.value >= avoidAt }.keys)
    }
}
