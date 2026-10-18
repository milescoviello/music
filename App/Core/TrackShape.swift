import Foundation

/// How a track starts and how it ends, as loudness over its first and last seconds —
/// what Sweet Fades needs to know to size the overlap between two tracks — and its
/// loudness all the way through, which the seekbar draws.
///
/// Measured from a file on the phone, a download or a cached stream, never from a
/// stream in flight: the end of a track is only readable once the whole file is here.
struct TrackShape: Codable, Hashable, Sendable {
    var intro: LoudnessRamp
    /// Index 0 is the last measurement, the track's end. See `LoudnessRamp`.
    var outro: LoudnessRamp
    /// Integrated loudness of the whole track. Used only for tracks the server has no
    /// ReplayGain for.
    var measuredLoudness: Double?
    /// The whole track's momentary loudness as the seekbar wants it: `levelPoints` means
    /// in LUFS over equal spans, start to end, of readings floored at `levelFloor` — the
    /// same as our sonic service's `/levels?points=128` and Plex's `?subsample=128`, so
    /// `SeekbarShape` draws either the same way. Optional: shapes measured before it
    /// existed have none, and are measured again.
    var levels: [Float]?

    static let levelPoints = 128
    /// Where Plex's readings bottom out. `SeekbarShape` draws nothing below −35 anyway;
    /// this keeps a long silence from dragging a bucket's mean down with it.
    static let levelFloor: Float = -40

    /// Momentary readings to the seekbar's levels: floored, then averaged in decibels over
    /// `points` equal spans, reading `i * n / points` up to the next. A track with no more
    /// readings than points keeps them all, and the seekbar interpolates between them.
    static func levels(fromMomentary readings: [Float], points: Int = levelPoints) -> [Float] {
        let floored = readings.map { max($0, levelFloor) }
        guard points > 0, floored.count > points else { return rounded(floored) }
        return rounded((0..<points).map { bucket in
            let span = floored[bucket * floored.count / points..<(bucket + 1) * floored.count / points]
            return span.reduce(0, +) / Float(span.count)
        })
    }

    /// One whole track's momentary readings (`LoudnessMeter.momentary`, a reading per
    /// `hop`), to its shape: the first and last `SweetFades.analysedSeconds` are the
    /// ramps, and all of it is the loudness and the seekbar's levels. Nil for nothing.
    static func measure(momentary readings: [Float], hop: Double = LoudnessMeter.hop) -> TrackShape? {
        guard !readings.isEmpty, hop > 0 else { return nil }
        let rampReadings = Int((SweetFades.analysedSeconds / hop).rounded())
        return TrackShape(
            intro: LoudnessRamp(levels: rounded(Array(readings.prefix(rampReadings))), hop: hop),
            // Measured forwards like everything else, read backwards from the end.
            outro: LoudnessRamp(levels: rounded(readings.suffix(rampReadings).reversed()), hop: hop),
            measuredLoudness: LoudnessMeter.integrated(readings),
            levels: levels(fromMomentary: readings)
        )
    }

    /// `channels` are a whole track, non-interleaved.
    static func measure(channels: [[Float]], sampleRate: Double) -> TrackShape? {
        measure(momentary: LoudnessMeter.momentary(channels: channels, sampleRate: sampleRate))
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
