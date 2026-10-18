import Foundation
import Testing
@testable import MusicLogic

struct VisualizerSpectrumTests {
    @Test func silenceIsZeroEverywhere() {
        var bands = [Float](repeating: 1, count: VisualizerSpectrum.bandCount)
        VisualizerSpectrum.bands(
            magnitudes: [Float](repeating: 0, count: VisualizerSpectrum.binCount),
            sampleRate: 44_100,
            into: &bands
        )
        #expect(bands.allSatisfy { $0 == 0 })
    }

    @Test func fullScaleIsPinnedWhereThePlexampCeilingIs() {
        var bands = [Float](repeating: 0, count: VisualizerSpectrum.bandCount)
        VisualizerSpectrum.bands(
            magnitudes: [Float](repeating: 100, count: VisualizerSpectrum.binCount),
            sampleRate: 48_000,
            into: &bands
        )
        // 61 / 86 / 1.5: the most any band can read.
        #expect(bands.allSatisfy { abs($0 - 0.4728682) < 1e-6 })
    }

    @Test func aToneLightsOnlyTheBandsAroundIt() {
        // Bin 20 at 44.1 kHz is about 1.7 kHz: well inside the 8 kHz the bands cover.
        var magnitudes = [Float](repeating: 0, count: VisualizerSpectrum.binCount)
        magnitudes[20] = 0.1
        var bands = [Float](repeating: 0, count: VisualizerSpectrum.bandCount)
        VisualizerSpectrum.bands(magnitudes: magnitudes, sampleRate: 44_100, into: &bands)

        let lit = bands.indices.filter { bands[$0] > 0 }
        #expect(!lit.isEmpty)
        #expect(lit.count < 6)
        // 20·log10(w × 0.1 × 2.5) + 61, over 129, with w the 468 gain near 1.7 kHz.
        let expected = (20 * log10f(VisualizerSpectrum.weighting(1722) * 0.25) + 61) / 129
        #expect(lit.contains { abs(bands[$0] - expected) < 0.01 })
    }

    @Test func the468CurveIsUnityAtOneKilohertzAndPeaksNearSix() {
        #expect(abs(VisualizerSpectrum.weighting(1000) - 1) < 0.02)
        let peak = 20 * log10(Double(VisualizerSpectrum.weighting(6300)))
        #expect(abs(peak - 12.2) < 0.3)
        #expect(VisualizerSpectrum.weighting(31) < VisualizerSpectrum.weighting(1000))
    }
}

struct VisualizerHostStateTests {
    private let data = VisualizerData(frequencyHistory: true, frequency: true, peaks: true, alpha: 0.3)

    private func flat(_ value: Float) -> [Float] {
        [Float](repeating: value, count: VisualizerHostState.bands)
    }

    @Test func aRiseIsSmoothedByAlpha() {
        var host = VisualizerHostState()
        host.tick(bands: flat(0.4), data: data)
        #expect(abs(host.frequencyTexels[0] - 0.12) < 1e-6)
        host.tick(bands: flat(0.4), data: data)
        #expect(abs(host.frequencyTexels[0] - (0.12 + (0.4 - 0.12) * 0.3)) < 1e-5)
    }

    @Test func aDropHoldsForTheFrameAfterARiseThenFalls() {
        var host = VisualizerHostState()
        host.tick(bands: flat(0.4), data: data)
        let risen = host.frequencyTexels[0]

        // The frame after a high subtracts 0² × 0.4: the level holds at 0.4, so the
        // smoothed value keeps climbing towards it.
        host.tick(bands: flat(0), data: data)
        let held = host.frequencyTexels[0]
        #expect(held > risen)

        // The next subtracts 0.4, which takes any level to the floor, and the smoothed
        // value starts to decay.
        host.tick(bands: flat(0), data: data)
        #expect(abs(host.frequencyTexels[0] - held * 0.7) < 1e-6)
    }

    @Test func aLevelUnbeatenForAHundredFramesStopsFalling() {
        var host = VisualizerHostState()
        let noPeaks = VisualizerData(frequency: true, alpha: 1)
        host.tick(bands: flat(0.4), data: noPeaks)
        for _ in 0..<100 { host.tick(bands: flat(0.4), data: noPeaks) }
        // The hold ran out while the music sat exactly at the level: nothing pulls it
        // down now, not even silence.
        host.tick(bands: flat(0), data: noPeaks)
        #expect(abs(host.frequencyTexels[0] - 0.4) < 1e-6)
    }

    @Test func peaksStayAboveTheAmplitudeAndFallSlowly() {
        var host = VisualizerHostState()
        for _ in 0..<40 { host.tick(bands: flat(0.4), data: data) }
        for _ in 0..<10 { host.tick(bands: flat(0), data: data) }

        let amplitude = host.frequencyTexels[0]
        let peak = host.frequencyTexels[VisualizerHostState.bands]
        #expect(peak > amplitude)
        #expect(peak > 0.35)
    }

    @Test func peaksAreLeftAloneForProgramsWithout() {
        var host = VisualizerHostState()
        var withoutPeaks = data
        withoutPeaks.peaks = false
        host.tick(bands: flat(0.4), data: withoutPeaks)
        #expect(host.frequencyTexels[VisualizerHostState.bands] == 0)
    }

    @Test func historyAdvancesEverySecondFrameAndWraps() {
        var host = VisualizerHostState()
        #expect(host.historyIndex == -1)
        host.tick(bands: flat(0.4), data: data)
        #expect(host.historyIndex == 0)
        host.tick(bands: flat(0.4), data: data)
        #expect(host.historyIndex == 0)
        host.tick(bands: flat(0.4), data: data)
        #expect(host.historyIndex == 1)

        for _ in 0..<(VisualizerHostState.historyRows * 2) { host.tick(bands: flat(0.4), data: data) }
        #expect(host.historyIndex == 1)
    }

    @Test func choosingAProgramWithoutHistoryClearsIt() {
        var host = VisualizerHostState()
        host.tick(bands: flat(0.4), data: data)
        host.select(VisualizerData())
        #expect(host.historyIndex == -1)
        #expect(host.historyTexels.allSatisfy { $0 == 0 })
    }
}

struct VisualizerCrossfadeTests {
    @Test func runsSixtyFramesThenSettles() {
        var fade = VisualizerCrossfade()
        #expect(fade.value == 1)
        fade.start()
        #expect(fade.value == 0)
        for _ in 0..<30 { fade.advance() }
        #expect(abs(fade.value - 0.5) < 1e-6)
        fade.start()
        #expect(abs(fade.value - 0.5) < 1e-6)
        for _ in 0..<31 { fade.advance() }
        #expect(fade.value == 1)
    }
}

struct VisualizerLoudnessTests {
    @Test func quietIsSilenceAndTheLoudestIsNormalised() {
        let texels = VisualizerLoudness.texels(from: [-60, -20, -40, -10])
        #expect(texels.count == VisualizerLoudness.texels)
        #expect(texels[0] == 0)
        // Both ends survive the resampling exactly, and the loudest is the last.
        let loudest: Float = 40.909088 / 50
        let last: Float = texels[VisualizerLoudness.texels - 1]
        #expect(abs(last - loudest) < 1e-6)
    }

    @Test func interpolationKeepsBothEnds() {
        let out = VisualizerLoudness.interpolate([0, 1], count: 5)
        #expect(out == [0, 0.25, 0.5, 0.75, 1])
    }
}

struct VisualizerPaletteTests {
    typealias RGB = VisualizerPalette.RGB

    @Test func hslMatchesColorConvert() {
        let red = VisualizerPalette.HSL(RGB(255, 0, 0))
        #expect(red.h == 0 && red.s == 100 && red.l == 50)
        let teal = VisualizerPalette.HSL(RGB(0, 128, 128))
        #expect(abs(teal.h - 180) < 1e-9)
        let back = teal.rgb.rounded
        #expect(back == RGB(0, 128, 128))
    }

    @Test func fourPicksAllAtPlexampsLightness() {
        let palette = (0..<20).map { (index: Int) -> RGB in
            let step = Double(index)
            return RGB(step * 12, 255 - step * 12, 80 + step * 5)
        }
        let picked = VisualizerPalette.pickCircularGradientColours(palette)
        #expect(picked.count == 4)
        for colour in picked {
            let lightness = VisualizerPalette.HSL(colour).l
            // 30 or 33, give or take the stretch apart and rounding to bytes.
            #expect(lightness > 18 && lightness < 45)
        }
    }

    @Test func theGradientIsThirtyTwoFromTheFourReversed() {
        let palette = [RGB](repeating: RGB(40, 120, 200), count: 20)
        let gradient = VisualizerPalette.gradient(fromQuadrantColours: palette)
        #expect(gradient.count == VisualizerPalette.size)
        // One colour four times is too samey, so each pair is pushed 10 points apart in
        // lightness: the ends differ, though the hue is the same throughout.
        #expect(gradient.first != gradient.last)
        #expect(gradient.allSatisfy { $0.b > $0.g && $0.g > $0.r })
    }

    @Test func interpolationTruncatesLikeTheOriginal() {
        let out = VisualizerPalette.interpolate([RGB(0, 0, 0), RGB(255, 255, 255)], count: 3)
        #expect(out.count == 3)
        #expect(out[0] == RGB(0, 0, 0))
        #expect(out[1].r == 127)
        #expect(out[2] == RGB(255, 255, 255))
    }

    @Test func colorCubeFindsEachCornersColour() {
        let width = 20
        let height = 20
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let colour: (UInt8, UInt8, UInt8) = switch (x < width / 2, y < height / 2) {
                case (true, true): (200, 40, 40)
                case (false, true): (40, 200, 40)
                case (false, false): (40, 40, 200)
                case (true, false): (200, 200, 40)
                }
                pixels[offset] = colour.0
                pixels[offset + 1] = colour.1
                pixels[offset + 2] = colour.2
                pixels[offset + 3] = 255
            }
        }

        let colours = ColorCube.quadrantColours(pixels: pixels, width: width, height: height)
        #expect(colours.count == 20)
        // Clockwise from the top left, five each, a lone colour repeated.
        #expect(colours[0] == RGB(200, 40, 40))
        #expect(colours[4] == RGB(200, 40, 40))
        #expect(colours[5] == RGB(40, 200, 40))
        #expect(colours[10] == RGB(40, 40, 200))
        #expect(colours[15] == RGB(200, 200, 40))
    }

    @Test func aBlackCornerFallsBackToUnfiltered() {
        let pixels = [UInt8](repeating: 0, count: 10 * 10 * 4)
        let colours = ColorCube.quadrantColours(pixels: pixels, width: 10, height: 10)
        #expect(colours.count == 20)
        #expect(colours.allSatisfy { $0 == RGB(0, 0, 0) })
    }
}
