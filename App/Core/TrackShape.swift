import Foundation

/// How a track starts and how it ends, as loudness over its first and last seconds —
/// what Sweet Fades needs to know to size the overlap between two tracks.
///
/// Measured from a file on the phone, a download or a cached stream, never from a
/// stream in flight: the end of a track is only readable once the whole file is here.
struct TrackShape: Codable, Hashable, Sendable {
    var intro: LoudnessRamp
    /// Index 0 is the last measurement, the track's end. See `LoudnessRamp`.
    var outro: LoudnessRamp
    /// Integrated loudness of what was measured. Used only for tracks the server has no
    /// ReplayGain for; the server's figure covers the whole track and is better.
    var measuredLoudness: Double?
    /// The whole track's loudness, start to end, as `envelopePoints` values from 0 (quiet)
    /// to 1 (its loudest): what Plexamp's seekbar draws. Optional, as shapes measured
    /// before it existed have none.
    var envelope: [Float]?

    static let envelopePoints = 120
    /// How far below the loudest point counts as silence on the seekbar.
    static let envelopeRange: Float = 36

    /// Mean-square power per equal slice of the track, to the seekbar's 0…1 scale: decibels
    /// relative to the loudest slice, floored `envelopeRange` below it.
    static func envelope(fromPower power: [Double]) -> [Float]? {
        guard !power.isEmpty, let loudest = power.max(), loudest > 0 else { return nil }
        let ceiling = 10 * log10(loudest)
        return power.map { value in
            guard value > 0 else { return 0 }
            let relative = Float(10 * log10(value) - ceiling)
            return max(0, (relative + envelopeRange) / envelopeRange)
        }
    }

    /// `intro` and `outro` are non-interleaved channels of the first and last
    /// `SweetFades.analysedSeconds` (or the whole track, if it is shorter).
    static func measure(intro: [[Float]], outro: [[Float]], sampleRate: Double, power: [Double]? = nil) -> TrackShape {
        let introLevels = LoudnessMeter.momentary(channels: intro, sampleRate: sampleRate)
        let outroLevels = LoudnessMeter.momentary(channels: outro, sampleRate: sampleRate)
        return TrackShape(
            intro: LoudnessRamp(levels: rounded(introLevels)),
            // Measured forwards like everything else, read backwards from the end.
            outro: LoudnessRamp(levels: rounded(outroLevels.reversed())),
            measuredLoudness: LoudnessMeter.integrated(introLevels + outroLevels),
            envelope: power.flatMap(envelope(fromPower:)).map { $0.map { ($0 * 100).rounded() / 100 } }
        )
    }

    /// A tenth of a decibel is far finer than any threshold this is compared against,
    /// and it keeps a stored shape to a kilobyte or so.
    private static func rounded(_ levels: [Float]) -> [Float] {
        levels.map { ($0 * 10).rounded() / 10 }
    }
}

/// Sweet Fades' decision for one transition, from everything known about the two tracks.
enum TransitionPlanner {
    /// Seconds of crossfade, or nil for gapless.
    ///
    /// Never with the setting off, and never within an album played in order. Otherwise
    /// the two shapes decide — and decide "gapless" too, when the outgoing track stops
    /// dead into one that starts dead. Only when either shape is unknown (a stream that
    /// has not been cached yet) is the overlap a guess.
    static func overlap(
        from current: Song,
        to next: Song,
        sweetFades: Bool,
        outgoing: TrackShape?,
        incoming: TrackShape?
    ) -> Double? {
        guard sweetFades, !SweetFades.isAlbumContinuation(from: current, to: next) else { return nil }
        guard let outgoing, let incoming else { return SweetFades.fallbackOverlap }

        return SweetFades.overlap(
            outgoing: outgoing.outro,
            outgoingLoudness: LoudnessLeveling.loudness(of: current.replayGain) ?? outgoing.measuredLoudness,
            incoming: incoming.intro,
            incomingLoudness: LoudnessLeveling.loudness(of: next.replayGain) ?? incoming.measuredLoudness
        )
    }
}
