import Foundation

/// Beat-matched fades: a Sweet Fade that lands the incoming track's beats on the outgoing
/// track's for the whole overlap, the way a DJ mixes — for the pairs whose tempos allow it.
///
/// The beats are our sonic service's (`SonicClient.Rhythm`), from Essentia's multi-feature
/// tracker run on the stored file. Two things about them shape this. Their times are
/// quantised to the tracker's 512-sample hop, 11.6 ms. And `bpm` is a whole-track figure
/// that often says little about a track's last or first fifteen seconds: on the first
/// tracks the service analysed, the tempo over the last eight seconds differed from it by
/// 9% at the median, because outros slow down, speed up and change metre. So `bpm` is
/// never used for timing. A straight beat grid is fitted to the beats actually inside the
/// overlap, on both sides, and the fade is matched only when both grids are steady — every
/// beat within a few milliseconds of its line — and their tempos are within a DJ's pitch
/// range of each other, or of half or double.
///
/// The incoming track still starts from its beginning, as in any Sweet Fade. What changes
/// is exactly when, and how fast: it starts so that its first beat lands on a beat of the
/// outgoing track, plays at the outgoing track's tempo through the overlap, and eases back
/// to its own over the two bars after. The overlap is a whole number of bars, as near to
/// what Sweet Fades chose as fits and as is steady.
///
/// Bars line up only by luck: the service finds beats, not downbeats, so beat one of one
/// track can land on beat three of the other. The beats themselves are what this matches.
enum BeatMatch {
    struct Plan: Equatable, Sendable {
        /// Seconds into the outgoing track at which the incoming one starts, from its own
        /// beginning.
        let start: Double
        /// How long the outgoing track is, as the plan was made for. The player checks it
        /// against the item it has: a plan for a different file would be confidently wrong.
        let outgoingDuration: Double
        /// The incoming track's speed through the overlap, relative to its own: what puts
        /// its tempo on the outgoing one's.
        let rate: Double
        /// Seconds, at the outgoing track's tempo, over which the incoming one eases back to
        /// its own once the overlap is over.
        let easeOut: Double
        /// Outgoing beats the overlap spans, give or take the incoming track's lead-in to its
        /// first beat: a whole number of bars.
        let beats: Int

        /// Seconds from `start` to the outgoing track's end.
        var overlap: Double { outgoingDuration - start }
    }

    /// The tracker's own confidence, below which its beats are not trusted. Essentia's
    /// scale runs to about 5.3; 1.5 to 3.5 is usable.
    static let minimumConfidence = 1.5
    /// A DJ's pitch fader. Beyond this the change of speed is a change of character.
    static let maximumRateChange = 0.08
    static let beatsPerBar = 4
    /// Two bars: anything shorter is over before a matched tempo can be heard as one.
    static let minimumBeats = 8
    static let easeBeats = 8
    /// How far any one beat may sit from its fitted grid, and the RMS across a window. The
    /// tracker's quantisation alone accounts for a few milliseconds; past these, the music
    /// itself is drifting, and two drifting tracks would flam.
    static let maximumDeviation = 0.030
    static let maximumRMSDeviation = 0.015
    /// The share of a window's beats that must be there. The tracker skips the odd beat;
    /// one that skips many has lost the pulse.
    static let minimumCoverage = 0.8

    /// A beat-matched version of a Sweet Fade of `overlap` seconds, or nil when the two
    /// tracks' beats do not allow one and the fade should go ahead as it is.
    ///
    /// `outgoingDuration` is the outgoing track's length if the player knows it better than
    /// the service; the service's own measurement otherwise.
    static func plan(
        outgoing: SonicClient.Rhythm,
        incoming: SonicClient.Rhythm,
        overlap: Double,
        outgoingDuration: Double? = nil
    ) -> Plan? {
        guard outgoing.bpm != nil, incoming.bpm != nil,
              (outgoing.confidence ?? 0) >= minimumConfidence,
              (incoming.confidence ?? 0) >= minimumConfidence,
              let end = outgoingDuration ?? outgoing.duration, end > 0
        else { return nil }

        // Rough tempos over the most an overlap can be, for sizing the windows and for
        // whether one track is at half or double the other's. Loosely: the grids decide.
        let horizon = SweetFades.maximumOverlap
        guard let outPeriod = typicalPeriod(outgoing.beats.filter { $0 >= end - horizon && $0 <= end }),
              let inPeriod = typicalPeriod(incoming.beats.filter { $0 <= horizon }),
              let rough = tempoMatch(incomingPeriod: inPeriod, outgoingPeriod: outPeriod, within: 2 * maximumRateChange)
        else { return nil }

        let barSeconds = outPeriod * Double(beatsPerBar)
        let fewest = minimumBeats / beatsPerBar
        let most = Int(horizon / barSeconds)
        guard most >= fewest else { return nil }
        let nearest = min(max(Int((overlap / barSeconds).rounded()), fewest), most)

        // Shorter overlaps are steadier — an outro that slows down often only does so in its
        // last few bars — so a pair that cannot be matched at Sweet Fades' length may still be
        // matched at a shorter one.
        for bars in stride(from: nearest, through: fewest, by: -1) {
            let beats = bars * beatsPerBar
            let span = Double(beats) * outPeriod
            // The incoming track's own seconds the overlap covers.
            let incomingSpan = span * min(max(rough.rate, 1 - maximumRateChange), 1 + maximumRateChange)

            guard let out = Grid.fit(outgoing.beats.filter { $0 >= end - span - outPeriod / 2 && $0 <= end }),
                  out.isSteady(expecting: span / out.period),
                  let into = Grid.fit(incoming.beats.filter { $0 <= incomingSpan + inPeriod / 2 }),
                  into.isSteady(expecting: incomingSpan / into.period)
            else { continue }

            // From the fitted grids, which are finer than any one beat.
            let rate = into.period / (rough.multiple * out.period)
            guard abs(rate - 1) <= maximumRateChange else { continue }

            // Outgoing seconds from the incoming track's start to its first beat.
            let lead = into.origin / rate
            // The outgoing beat that first beat lands on: whichever makes the overlap nearest
            // `beats` long. Any outgoing beat will do for a track at half or double the tempo
            // too — its beats then fall on every other one, or on and between them.
            var landing = ((end - span + lead - out.origin) / out.period).rounded()
            var start = out.origin + landing * out.period - lead
            while end - start > horizon {
                landing += 1
                start = out.origin + landing * out.period - lead
            }
            guard start > 0, end - start >= SweetFades.minimumOverlap else { continue }

            return Plan(
                start: start,
                outgoingDuration: end,
                rate: rate,
                easeOut: Double(easeBeats) * out.period,
                beats: beats
            )
        }
        return nil
    }

    /// The incoming track's speed that puts its beats on the outgoing one's — or on every
    /// other one, or on and between them, for a track the tracker heard at half or double
    /// the tempo — and which of those it is. Nil when none is `within` of unchanged.
    static func tempoMatch(
        incomingPeriod: Double,
        outgoingPeriod: Double,
        within limit: Double = maximumRateChange
    ) -> (multiple: Double, rate: Double)? {
        guard incomingPeriod > 0, outgoingPeriod > 0 else { return nil }
        let ratio = incomingPeriod / outgoingPeriod
        let best = [1, 2, 0.5]
            .map { (multiple: $0, rate: ratio / $0) }
            .min { abs($0.rate - 1) < abs($1.rate - 1) }
        guard let best, abs(best.rate - 1) <= limit else { return nil }
        return best
    }

    /// The median gap between consecutive beats: a tempo that one skipped or doubled beat
    /// does not move. Nil for too few beats to say.
    static func typicalPeriod(_ beats: [Double]) -> Double? {
        guard beats.count >= 4 else { return nil }
        let gaps = zip(beats.dropFirst(), beats).map { $0 - $1 }.sorted()
        let median = gaps[gaps.count / 2]
        return median > 0 ? median : nil
    }

    /// A straight line through a run of beats: beat `k` at `origin + period * k`, where beat
    /// 0 is the run's first.
    struct Grid: Equatable, Sendable {
        let origin: Double
        let period: Double
        /// Beats the line was fitted to.
        let count: Int
        /// Beats the run spans, first to last, counting any the tracker missed.
        let span: Int
        let rmsDeviation: Double
        let maximumDeviation: Double

        /// Each beat is numbered by rounding its distance from the first in the run's own
        /// typical gap, so a beat the tracker missed costs only its own absence; then a
        /// least-squares line through the numbered beats. Nil for fewer than four, or two
        /// that round to the same number.
        static func fit(_ beats: [Double]) -> Grid? {
            guard let gap = BeatMatch.typicalPeriod(beats), let first = beats.first else { return nil }
            let numbers = beats.map { (($0 - first) / gap).rounded() }
            guard Set(numbers).count == numbers.count, let last = numbers.last else { return nil }

            let count = Double(beats.count)
            let meanNumber = numbers.reduce(0, +) / count
            let meanTime = beats.reduce(0, +) / count
            var covariance = 0.0
            var variance = 0.0
            for (number, time) in zip(numbers, beats) {
                covariance += (number - meanNumber) * (time - meanTime)
                variance += (number - meanNumber) * (number - meanNumber)
            }
            guard variance > 0 else { return nil }
            let period = covariance / variance
            let origin = meanTime - period * meanNumber

            let deviations = zip(numbers, beats).map { abs($1 - (origin + period * $0)) }
            return Grid(
                origin: origin,
                period: period,
                count: beats.count,
                span: Int(last) + 1,
                rmsDeviation: (deviations.reduce(0) { $0 + $1 * $1 } / count).squareRoot(),
                maximumDeviation: deviations.max() ?? 0
            )
        }

        /// Steady enough to match against: every beat close to the line, and most of the
        /// `expected` beats there at all.
        func isSteady(expecting expected: Double) -> Bool {
            period > 0
                && maximumDeviation <= BeatMatch.maximumDeviation
                && rmsDeviation <= BeatMatch.maximumRMSDeviation
                && Double(count) >= BeatMatch.minimumCoverage * expected
        }
    }
}
