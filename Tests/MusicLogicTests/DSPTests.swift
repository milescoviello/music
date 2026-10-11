import Foundation
import Testing
@testable import MusicLogic

/// None of the audio chain can be heard from CI, so these pin it numerically: filters
/// shaped as designed, gains as Plexamp computes them, a limiter that never lets a
/// sample through above its ceiling, and Sweet Fades' overlap rule.
struct DSPTests {
    // MARK: - Helpers

    private func sine(
        frequency: Double,
        amplitude: Float,
        seconds: Double,
        sampleRate: Double = 48_000
    ) -> [Float] {
        let count = Int(seconds * sampleRate)
        return (0..<count).map { index in
            amplitude * Float(sin(2 * Double.pi * frequency * Double(index) / sampleRate))
        }
    }

    private func peak(_ samples: ArraySlice<Float>) -> Float {
        samples.reduce(0) { max($0, abs($1)) }
    }

    /// Runs one channel through a chain, in buffers the size a tap would deliver.
    private func run(_ chain: DSPChain, _ input: [Float], buffer: Int = 512) -> [Float] {
        var samples = input
        samples.withUnsafeMutableBufferPointer { all in
            var offset = 0
            while offset < all.count {
                let frames = min(buffer, all.count - offset)
                var pointers = [all.baseAddress! + offset]
                pointers.withUnsafeMutableBufferPointer { channels in
                    chain.process(channels, frames: frames)
                }
                offset += frames
            }
        }
        return samples
    }

    // MARK: - Loudness Leveling

    @Test func levelingUsesAlbumGainPlusPreamp() {
        let gain = ReplayGain(trackGain: -9, albumGain: -7, trackPeak: 1, albumPeak: 1)
        let applied = LoudnessLeveling.gain(for: gain, isEnabled: true, preamp: 4, limiter: true)
        #expect(applied == -3)
    }

    @Test func levelingFallsBackToTrackGainForAnUnanalysedAlbum() {
        let gain = ReplayGain(trackGain: -9)
        #expect(LoudnessLeveling.gain(for: gain, isEnabled: true, preamp: 0, limiter: true) == -9)
    }

    @Test func nothingIsAppliedWithoutGainDataOrWhenOff() {
        #expect(LoudnessLeveling.gain(for: nil, isEnabled: true, preamp: 4, limiter: true) == nil)
        #expect(LoudnessLeveling.gain(for: ReplayGain(), isEnabled: true, preamp: 4, limiter: true) == nil)
        let gain = ReplayGain(albumGain: -7)
        #expect(LoudnessLeveling.gain(for: gain, isEnabled: false, preamp: 4, limiter: true) == nil)
    }

    @Test func withoutTheLimiterTheGainCannotClipTheTracksOwnPeak() {
        // A quiet master: +6 wanted, but its peak is at -2 dBFS, so only +2 is safe.
        let gain = ReplayGain(albumGain: 2, albumPeak: Decibels.linear(-2.0))
        let applied = LoudnessLeveling.gain(for: gain, isEnabled: true, preamp: 4, limiter: false)
        #expect(abs((applied ?? 0) - 2) < 0.001)
        // With the limiter there to catch the peaks, the full gain goes through.
        #expect(LoudnessLeveling.gain(for: gain, isEnabled: true, preamp: 4, limiter: true) == 6)
    }

    @Test func loudnessIsRecoveredFromTheGain() {
        #expect(LoudnessLeveling.loudness(of: ReplayGain(trackGain: -8)) == -10)
    }

    // MARK: - Filters

    @Test func aPeakingBandBoostsItsCentreByItsGainAndLeavesTheRestAlone() {
        let band = Biquad.peaking(frequency: 1_000, gain: 6, octaves: 1, sampleRate: 48_000)
        #expect(abs(band.response(at: 1_000, sampleRate: 48_000) - 6) < 0.05)
        #expect(abs(band.response(at: 50, sampleRate: 48_000)) < 0.3)
        #expect(abs(band.response(at: 15_000, sampleRate: 48_000)) < 0.3)
    }

    @Test func anOctaveBandIsAtHalfGainAnOctaveAway() {
        let band = Biquad.peaking(frequency: 1_000, gain: 12, octaves: 1, sampleRate: 48_000)
        let atHalfOctave = band.response(at: 1_000 * pow(2, 0.5), sampleRate: 48_000)
        #expect(abs(atHalfOctave - 6) < 0.6)
    }

    @Test func aBandPastNyquistIsDroppedNotBuilt() {
        let band = Biquad.peaking(frequency: 16_000, gain: 6, octaves: 1, sampleRate: 32_000)
        #expect(band.isIdentity)
        #expect(Biquad.peaking(frequency: 1_000, gain: 0, octaves: 1, sampleRate: 48_000).isIdentity)
    }

    // MARK: - The chain

    @Test func aFlatChainWithNoGainIsBitTransparent() {
        let settings = DSPSettingsStore()
        settings.update { $0.loudnessLeveling = false; $0.limiter = false }
        let chain = DSPChain(replayGain: nil, settings: settings)
        chain.prepare(sampleRate: 48_000, channels: 1)

        let input = sine(frequency: 440, amplitude: 0.5, seconds: 0.1)
        #expect(run(chain, input) == input)
    }

    @Test func theTrackGainIsApplied() {
        let settings = DSPSettingsStore()
        settings.update { $0.preamp = 0; $0.limiter = false }
        let chain = DSPChain(replayGain: ReplayGain(albumGain: -6), settings: settings)
        chain.prepare(sampleRate: 48_000, channels: 1)

        let output = run(chain, sine(frequency: 440, amplitude: 0.8, seconds: 0.2))
        // -6 dB is half amplitude, near enough.
        #expect(abs(peak(output[4_800...]) - 0.8 * Decibels.linear(Float(-6))) < 0.005)
    }

    @Test func anEqBoostRaisesItsBand() {
        let settings = DSPSettingsStore()
        settings.update {
            $0.loudnessLeveling = false
            $0.limiter = false
            $0.equalizer = true
            $0.bands[5] = 6 // 1 kHz
        }
        let chain = DSPChain(replayGain: nil, settings: settings)
        chain.prepare(sampleRate: 48_000, channels: 1)

        let output = run(chain, sine(frequency: 1_000, amplitude: 0.25, seconds: 0.3))
        let gain = Decibels.from(linear: Double(peak(output[9_600...]) / 0.25))
        #expect(abs(gain - 6) < 0.3)
    }

    @Test func theLimiterNeverLetsASampleOutAboveItsCeiling() {
        let settings = DSPSettingsStore()
        settings.update { $0.preamp = 0 }
        // +12 dB on a signal already at 0.9 would be 3.6x full scale without it.
        let chain = DSPChain(replayGain: ReplayGain(albumGain: 12), settings: settings)
        chain.prepare(sampleRate: 48_000, channels: 1)

        let output = run(chain, sine(frequency: 100, amplitude: 0.9, seconds: 0.5))
        #expect(peak(output[...]) <= DSPChain.limiterCeiling + 0.0001)
    }

    @Test func aSettingsChangeIsPickedUpMidStreamAndRampedNotStepped() {
        let settings = DSPSettingsStore()
        settings.update { $0.preamp = 0; $0.limiter = false }
        let chain = DSPChain(replayGain: ReplayGain(albumGain: 0), settings: settings)
        chain.prepare(sampleRate: 48_000, channels: 1)

        let input = [Float](repeating: 0.5, count: 512)
        let before = run(chain, input)
        #expect(before.allSatisfy { abs($0 - 0.5) < 0.0001 })

        settings.update { $0.preamp = -6 }
        let during = run(chain, input)
        // The first sample has barely moved; the last has arrived.
        #expect(during[0] > 0.49)
        #expect(abs(during[511] - 0.5 * Decibels.linear(Float(-6))) < 0.002)
    }

    // MARK: - Loudness measurement

    @Test func aFullScaleSineMeasuresAboutMinusThreeLUFS() {
        // BS.1770's own calibration point: a 0 dBFS 997 Hz sine in one channel reads -3.01.
        let levels = LoudnessMeter.momentary(
            channels: [sine(frequency: 997, amplitude: 1, seconds: 2)],
            sampleRate: 48_000
        )
        let settled = levels.dropFirst(5).dropLast(5)
        #expect(settled.allSatisfy { abs($0 - -3.01) < 0.3 })
    }

    @Test func integratedLoudnessIgnoresSilence() {
        var samples = sine(frequency: 997, amplitude: 0.1, seconds: 3)
        samples += [Float](repeating: 0, count: 48_000 * 3)
        let levels = LoudnessMeter.momentary(channels: [samples], sampleRate: 48_000)
        let integrated = LoudnessMeter.integrated(levels) ?? 0
        // -20 dBFS sine, -3 dB for being one channel's worth: about -23, silence or not.
        #expect(abs(integrated - -23) < 0.6)
    }

    // MARK: - Ramps and Sweet Fades

    @Test func aRampInterpolatesBetweenMeasurements() {
        let ramp = LoudnessRamp(levels: [-40, -30, -20, -10], hop: 0.1)
        #expect(abs(ramp.time(toReach: -25) - 0.15) < 0.0001)
        #expect(ramp.time(toReach: -50) == 0)
        // Never reached: no ramp, which means no overlap from this side.
        #expect(ramp.time(toReach: -5) == 0)
    }

    @Test func overlapIsTheOutrosTailPlusTheIntrosBuild() {
        // A fade-out: 4 s before the end it drops below loudness + 2. An intro that takes
        // 2 s to get there. Overlap 6 s, so the loud parts meet end to end.
        let outro = LoudnessRamp(levels: (0..<150).map { $0 < 40 ? -30 : -8 }, hop: 0.1)
        let intro = LoudnessRamp(levels: (0..<150).map { $0 < 20 ? -30 : -8 }, hop: 0.1)

        let overlap = SweetFades.overlap(
            outgoing: outro, outgoingLoudness: -10,
            incoming: intro, incomingLoudness: -10
        )
        #expect(abs((overlap ?? 0) - 6) < 0.001)
    }

    @Test func twoAbruptTracksAreLeftGapless() {
        let loud = LoudnessRamp(levels: [Float](repeating: -6, count: 150), hop: 0.1)
        let overlap = SweetFades.overlap(
            outgoing: loud, outgoingLoudness: -10,
            incoming: loud, incomingLoudness: -10
        )
        #expect(overlap == nil)
    }

    @Test func theOverlapIsCappedAtFifteenSeconds() {
        let ambient = LoudnessRamp(levels: (0..<150).map { $0 < 140 ? -40 : -8 }, hop: 0.1)
        let overlap = SweetFades.overlap(
            outgoing: ambient, outgoingLoudness: -10,
            incoming: ambient, incomingLoudness: -10
        )
        #expect(overlap == SweetFades.maximumOverlap)
    }

    @Test func nothingMeasuredMeansNoComputedOverlap() {
        let ramp = LoudnessRamp(levels: [-8], hop: 0.1)
        #expect(SweetFades.overlap(outgoing: nil, outgoingLoudness: -10, incoming: ramp, incomingLoudness: -10) == nil)
    }

    @Test func albumOrderIsGaplessAndAnythingElseFades() {
        func song(_ id: String, album: String?, disc: Int? = 1, track: Int?) -> Song {
            var song = Song(id: id, title: id)
            song.albumId = album
            song.discNumber = disc
            song.track = track
            return song
        }
        let one = song("1", album: "A", track: 1)
        let two = song("2", album: "A", track: 2)
        let lastOfDisc1 = song("9", album: "A", disc: 1, track: 9)
        let firstOfDisc2 = song("10", album: "A", disc: 2, track: 1)
        let elsewhere = song("x", album: "B", track: 2)

        #expect(SweetFades.isAlbumContinuation(from: one, to: two))
        #expect(SweetFades.isAlbumContinuation(from: lastOfDisc1, to: firstOfDisc2))
        #expect(!SweetFades.isAlbumContinuation(from: two, to: one))
        #expect(!SweetFades.isAlbumContinuation(from: one, to: song("3", album: "A", track: 3)))
        #expect(!SweetFades.isAlbumContinuation(from: one, to: elsewhere))
        #expect(SweetFades.isAlbumContinuation(from: song("a", album: "A", track: nil), to: song("b", album: "A", track: nil)))
    }
}
