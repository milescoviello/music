import Foundation
import Testing
@testable import MusicLogic

/// A beat-matched fade cannot be heard from CI either, so these pin where every incoming
/// beat lands: on an outgoing one, for the whole overlap, or no plan at all.
struct BeatMatchTests {
    // MARK: - Helpers

    private func rhythm(
        bpm: Double,
        firstBeat: Double = 0.4,
        duration: Double = 240,
        confidence: Double = 3,
        beats: [Double]? = nil
    ) -> SonicClient.Rhythm {
        let period = 60 / bpm
        let count = Int((duration - firstBeat) / period) + 1
        return SonicClient.Rhythm(
            id: "song",
            bpm: bpm,
            confidence: confidence,
            beats: beats ?? (0..<count).map { firstBeat + Double($0) * period },
            key: nil,
            scale: nil,
            keyStrength: nil,
            duration: duration,
            loudness: nil
        )
    }

    /// Where the incoming track's beats are heard, in outgoing seconds, for those that are
    /// heard before the outgoing track ends.
    private func heard(_ incoming: SonicClient.Rhythm, with plan: BeatMatch.Plan) -> [Double] {
        incoming.beats.map { plan.start + $0 / plan.rate }.filter { $0 <= plan.outgoingDuration }
    }

    /// The furthest any of `times` is from its nearest in `beats`.
    private func worstOffset(_ times: [Double], from beats: [Double]) -> Double {
        times.map { time in beats.map { abs($0 - time) }.min() ?? .infinity }.max() ?? .infinity
    }

    // MARK: - Matching

    @Test func twoSteadyTracksAtOneTempoLandBeatOnBeat() throws {
        let outgoing = rhythm(bpm: 120, firstBeat: 0.25, duration: 200)
        let incoming = rhythm(bpm: 120, firstBeat: 0.37)
        let plan = try #require(BeatMatch.plan(outgoing: outgoing, incoming: incoming, overlap: 6))

        #expect(abs(plan.rate - 1) < 1e-9)
        // Six seconds at 120 is three bars.
        #expect(plan.beats == 12)
        #expect(abs(plan.overlap - 6) <= 0.5)
        let landed = heard(incoming, with: plan)
        #expect(landed.count >= 11)
        #expect(worstOffset(landed, from: outgoing.beats) < 1e-6)
    }

    @Test func aCloseTempoIsPlayedAtTheOutgoingOne() throws {
        let outgoing = rhythm(bpm: 124)
        let incoming = rhythm(bpm: 120, firstBeat: 0.61)
        let plan = try #require(BeatMatch.plan(outgoing: outgoing, incoming: incoming, overlap: 8))

        // Sped up from 120 to 124 through the overlap.
        #expect(abs(plan.rate - 124.0 / 120) < 1e-9)
        #expect(worstOffset(heard(incoming, with: plan), from: outgoing.beats) < 1e-6)
        // Back to its own tempo over the two bars after, at the tempo it was matched to.
        #expect(abs(plan.easeOut - 8 * 60 / 124) < 1e-9)
    }

    @Test func tempiTooFarApartAreLeftAlone() {
        let outgoing = rhythm(bpm: 120)
        #expect(BeatMatch.plan(outgoing: outgoing, incoming: rhythm(bpm: 135), overlap: 6) == nil)
        #expect(BeatMatch.plan(outgoing: outgoing, incoming: rhythm(bpm: 111), overlap: 6) == nil)
        #expect(BeatMatch.plan(outgoing: outgoing, incoming: rhythm(bpm: 128), overlap: 6) != nil)
    }

    @Test func halfAndDoubleTimeStillMatch() throws {
        let outgoing = rhythm(bpm: 140)

        // Heard at half the tempo: its beats fall on every other outgoing one.
        let half = rhythm(bpm: 71, firstBeat: 0.9)
        let slow = try #require(BeatMatch.plan(outgoing: outgoing, incoming: half, overlap: 6))
        #expect(abs(slow.rate - 140.0 / 142) < 1e-9)
        #expect(worstOffset(heard(half, with: slow), from: outgoing.beats) < 1e-6)

        // At double: on every outgoing beat, and between them.
        let double = rhythm(bpm: 276, firstBeat: 0.2)
        let fast = try #require(BeatMatch.plan(outgoing: outgoing, incoming: double, overlap: 6))
        let halves = outgoing.beats.flatMap { [$0, $0 + 30.0 / 140] }
        #expect(worstOffset(heard(double, with: fast), from: halves) < 1e-6)
    }

    // MARK: - The overlap

    @Test func theOverlapIsWholeBarsNearSweetFades() throws {
        func beats(_ overlap: Double, bpm: Double = 120) throws -> Int {
            try #require(BeatMatch.plan(outgoing: rhythm(bpm: bpm), incoming: rhythm(bpm: bpm), overlap: overlap)).beats
        }

        // Two bars at the least, however short the Sweet Fade.
        #expect(try beats(1) == 8)
        // 4.5 bars rounds to five.
        #expect(try beats(9) == 20)
        // Never past Sweet Fades' fifteen seconds: seven bars at 120.
        #expect(try beats(40) == 28)
        // At 90, five bars is the most that fits.
        #expect(try beats(15, bpm: 90) == 20)
    }

    @Test func theOverlapNeverRunsPastSweetFadesCap() throws {
        // Seven bars at 113 is 14.9 seconds, so landing the incoming track's first beat on
        // the nearest outgoing one would often overrun; the plan lands it a beat later.
        let outgoing = rhythm(bpm: 113)
        for firstBeat in stride(from: 0.1, through: 1.3, by: 0.2) {
            let incoming = rhythm(bpm: 113, firstBeat: firstBeat)
            let plan = try #require(BeatMatch.plan(outgoing: outgoing, incoming: incoming, overlap: 40))
            #expect(plan.overlap <= SweetFades.maximumOverlap)
            #expect(plan.overlap > SweetFades.maximumOverlap - 60 / 113)
            #expect(worstOffset(heard(incoming, with: plan), from: outgoing.beats) < 1e-6)
        }
    }

    @Test func thePlayersDurationIsTheOneUsed() throws {
        let outgoing = rhythm(bpm: 120, duration: 200)
        let plan = try #require(BeatMatch.plan(outgoing: outgoing, incoming: rhythm(bpm: 120), overlap: 6, outgoingDuration: 199.5))
        #expect(plan.outgoingDuration == 199.5)
        #expect(plan.start < 199.5 - 4)
    }

    // MARK: - What is left alone

    @Test func untrustedOrMissingBeatsAreLeftAlone() {
        let steady = rhythm(bpm: 120)
        #expect(BeatMatch.plan(outgoing: rhythm(bpm: 120, confidence: 1.2), incoming: steady, overlap: 6) == nil)
        #expect(BeatMatch.plan(outgoing: steady, incoming: rhythm(bpm: 120, confidence: 0.4), overlap: 6) == nil)
        #expect(BeatMatch.plan(outgoing: steady, incoming: rhythm(bpm: 120, beats: []), overlap: 6) == nil)
        let noTempo = SonicClient.Rhythm(
            id: "song", bpm: nil, confidence: nil, beats: [], key: nil, scale: nil,
            keyStrength: nil, duration: 200, loudness: nil
        )
        #expect(BeatMatch.plan(outgoing: noTempo, incoming: steady, overlap: 6) == nil)
        #expect(BeatMatch.plan(outgoing: steady, incoming: noTempo, overlap: 6) == nil)
    }

    @Test func theTrackersOwnQuantisationIsTolerated() throws {
        // Every beat up to half a hop (5.8 ms) off, alternately early and late.
        let jitter = [0.0058, -0.0058, 0.003, -0.004]
        let out = rhythm(bpm: 120).beats.enumerated().map { $1 + jitter[$0 % jitter.count] }
        let into = rhythm(bpm: 120).beats.enumerated().map { $1 - jitter[$0 % jitter.count] }
        let outgoing = rhythm(bpm: 120, beats: out)
        let incoming = rhythm(bpm: 120, beats: into)
        let plan = try #require(BeatMatch.plan(outgoing: outgoing, incoming: incoming, overlap: 6))
        #expect(worstOffset(heard(incoming, with: plan), from: outgoing.beats) < 0.015)
    }

    @Test func aDriftingBeatIsLeftAlone() {
        // A beat 50 ms off in every bar: a performance that is not on a grid.
        let drifting = rhythm(bpm: 120).beats.enumerated().map { $0 % 4 == 2 ? $1 + 0.05 : $1 }
        #expect(BeatMatch.plan(outgoing: rhythm(bpm: 120, beats: drifting), incoming: rhythm(bpm: 120), overlap: 6) == nil)
        #expect(BeatMatch.plan(outgoing: rhythm(bpm: 120), incoming: rhythm(bpm: 120, beats: drifting), overlap: 6) == nil)
    }

    @Test func aMissedBeatCostsNothing() throws {
        let outgoing = rhythm(bpm: 120)
        var beats = outgoing.beats
        beats.remove(at: beats.count - 4)
        let plan = try #require(BeatMatch.plan(outgoing: rhythm(bpm: 120, beats: beats), incoming: rhythm(bpm: 120), overlap: 6))
        #expect(worstOffset(heard(rhythm(bpm: 120), with: plan), from: outgoing.beats) < 1e-6)
    }

    @Test func anOutroThatSlowsIsLeftAlone() {
        // Steady at 120, then slowing by 3% a beat for its last twelve.
        var beats = rhythm(bpm: 120, duration: 200).beats.filter { $0 < 190 }
        var gap = 0.5
        while let last = beats.last, last + gap < 199.8 {
            gap *= 1.03
            beats.append(last + gap)
        }
        #expect(BeatMatch.plan(outgoing: rhythm(bpm: 120, duration: 200, beats: beats), incoming: rhythm(bpm: 120), overlap: 6) == nil)
    }

    @Test func aLongIntroBeforeTheBeatIsLeftAlone() {
        // Nothing to match for the first six seconds.
        #expect(BeatMatch.plan(outgoing: rhythm(bpm: 120), incoming: rhythm(bpm: 120, firstBeat: 6), overlap: 4) == nil)
    }

    // MARK: - Real tracks

    /// The last sixteen seconds of one track and the first sixteen of another, as the sonic
    /// service measured them: tempos that wander by a few percent at the end, beats on an
    /// 11.6 ms grid. The outgoing one is only steady over its last two bars.
    @Test func realBeatsFromTheService() throws {
        let outgoing = SonicClient.Rhythm(
            id: "0Q4cn3k7QSzm6XhVGMvfHy", bpm: 150.19, confidence: 2.48,
            beats: [
                114.695, 115.101, 115.496, 115.891, 116.286, 116.68, 117.087, 117.493, 117.888,
                118.282, 118.689, 119.095, 119.49, 119.885, 120.291, 120.686, 121.092, 121.498,
                121.928, 122.346, 122.764, 123.182, 123.623, 124.064, 124.505, 124.877, 125.248,
                125.62, 125.991, 126.409, 126.827, 127.245, 127.663, 128.081, 128.499, 128.917,
                129.347, 129.776,
            ],
            key: nil, scale: nil, keyStrength: nil, duration: 130.31, loudness: nil
        )
        let incoming = SonicClient.Rhythm(
            id: "47ey5wcfGEq6VOe5aOSLqm", bpm: 147.51, confidence: 1.623,
            beats: [
                0.395, 0.813, 1.231, 1.649, 2.067, 2.485, 2.902, 3.32, 3.738, 4.156, 4.574, 4.992,
                5.41, 5.828, 6.246, 6.653, 7.082, 7.512, 7.93, 8.359, 8.777, 9.195, 9.613, 10.031,
                10.449, 10.867, 11.285, 11.703, 12.132, 12.562, 13.003, 13.444, 13.886, 14.327,
                14.791, 15.244, 15.697,
            ],
            key: nil, scale: nil, keyStrength: nil, duration: 128.92, loudness: nil
        )

        let plan = try #require(BeatMatch.plan(outgoing: outgoing, incoming: incoming, overlap: 6))
        #expect(plan.beats == 8)
        #expect(abs(plan.rate - 1) < 0.02)
        // Every incoming beat within the tracker's own precision of an outgoing one — up to
        // the outgoing track's last beat, half a second before its end.
        let landed = heard(incoming, with: plan).filter { $0 <= 129.776 + 0.05 }
        #expect(landed.count >= 6)
        #expect(worstOffset(landed, from: outgoing.beats) < 0.012)
    }

    /// A real outro that slows from 115 to 101 over its last fifteen seconds and settles
    /// for the last few: never matched to a track at the tempo it started at.
    @Test func aRealRitardandoIsLeftAlone() {
        let outgoing = SonicClient.Rhythm(
            id: "00BukajWg5OwVIO3UlXk4H", bpm: 115.3, confidence: 3.285,
            beats: [
                333.88, 334.402, 334.925, 335.435, 335.946, 336.469, 336.991, 337.502, 338.024,
                338.547, 339.058, 339.58, 340.091, 340.602, 341.124, 341.635, 342.169, 342.692,
                343.237, 343.783, 344.34, 344.909, 345.49, 346.059, 346.639, 347.231, 347.823,
                348.415, 348.996,
            ],
            key: nil, scale: nil, keyStrength: nil, duration: 349.59, loudness: nil
        )
        #expect(BeatMatch.plan(outgoing: outgoing, incoming: rhythm(bpm: 115), overlap: 8) == nil)
    }

    // MARK: - The grid

    @Test func theGridIsFittedThroughAMissedBeat() throws {
        let beats = [10.0, 10.5, 11.0, 12.0, 12.5, 13.0]
        let grid = try #require(BeatMatch.Grid.fit(beats))
        #expect(abs(grid.period - 0.5) < 1e-9)
        #expect(abs(grid.origin - 10) < 1e-9)
        #expect(grid.count == 6)
        #expect(grid.span == 7)
        #expect(grid.maximumDeviation < 1e-9)
        #expect(BeatMatch.Grid.fit([1, 2, 3]) == nil)
    }
}
