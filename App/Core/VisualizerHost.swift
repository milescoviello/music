import Foundation

/// What a visualiser asks of the audio, from its Plexamp config's `data` block.
///
/// `alpha` is not opacity, whatever the name suggests: it is the smoothing weight each
/// frame gives the new level against the old one. Plexamp's native host defaults it to
/// 0.3 when a program's config leaves it out, which most do.
struct VisualizerData: Sendable, Equatable {
    var frequencyHistory = false
    var frequency = true
    var peaks = false
    var alpha: Float = 0.3

    /// Nothing at all is analysed for a program that asks for none of it (Soundprint
    /// draws only the track's loudness, which is known in advance).
    var wantsSpectrum: Bool { frequencyHistory || frequency || peaks }
}

/// Plexamp's spectrum, from FFT magnitudes to the 64 bands every visualiser reads.
///
/// A port of `Utils::ProcessFrequencyData` in Plexamp's native engine (treble). The
/// numbers below are its constants, not taste: change one and every visualiser moves
/// differently from Plexamp's.
enum VisualizerSpectrum {
    static let bandCount = 64
    /// BASS_DATA_FFT512: 512 samples in, 256 magnitudes out.
    static let fftSize = 512
    static let binCount = fftSize / 2

    /// The 64 band levels for one FFT, each in 0...~0.473.
    ///
    /// - Only the bins up to 8 kHz are used, spread over the bands on a log2 scale: each
    ///   band ends at bin `2^(i * log2(bins) / 63)` and starts where the last one ended,
    ///   always at least one bin wide.
    /// - A band is the loudest bin in it, weighted by ITU-R 468 at the band's top edge,
    ///   times 2.5.
    /// - Then decibels: `20 log10(v) + 61` over 86 over 1.5, so 61 dB of range below
    ///   full scale, and anything at or past full scale pinned to 61/129.
    static func bands(magnitudes: [Float], sampleRate: Int, into output: inout [Float]) {
        let count = magnitudes.count
        let bandCount = output.count
        guard count > 1, bandCount > 1, sampleRate > 0 else {
            for index in output.indices { output[index] = 0 }
            return
        }

        let nyquist = Double(sampleRate) * 0.5
        let usable = Int(Double(count) / (nyquist / 8000))
        let exponent = log2(Double(usable))

        var start = 0
        for band in 0..<bandCount {
            var end = Int(pow(2, Double(band) * exponent / Double(bandCount - 1)))
            if end >= usable { end = usable - 1 }
            if end <= start { end = start + 1 }

            var peak: Float = 0
            var bin = start + 1
            while bin <= end, bin < count {
                if magnitudes[bin] > peak { peak = magnitudes[bin] }
                bin += 1
            }

            let frequency = Int(Float(end) / Float(count) * Float(sampleRate) * 0.5)
            let value = weighting(frequency) * peak * 2.5
            if value < 1 {
                let decibels = (log10f(value) * 20 + 96) - 35
                output[band] = decibels > 0 ? decibels / 86 / 1.5 : 0
            } else {
                output[band] = 0.4728682
            }
            start = end
        }
    }

    /// ITU-R 468 weighting as a linear gain, normalised so 1 kHz is unity (the +18.2 dB
    /// the standard adds). It lifts the presence region — +12 dB around 6 kHz — which is
    /// why treble moves Plexamp's bars more than a flat spectrum would.
    static func weighting(_ frequency: Int) -> Float {
        let f: Double = Double(frequency)
        let f2: Double = Double(Float(frequency) * Float(frequency))
        let f4: Double = f2 * f2

        // Spelled out term by term: as one expression this is too much for the type
        // checker on the CI's compiler.
        let h1a: Double = -4.737338981378384e-24 * f4 * f2
        let h1b: Double = 2.043828333606125e-15 * f4
        let h1c: Double = 1.363894795463638e-07 * f2
        let h1 = Float(h1a + h1b - h1c + 1)

        let h2a: Double = 5.559488023498642e-04 * f
        let h2b: Double = 1.306612257412824e-19 * f4 * f
        let h2c: Double = f2 * 2.118150887518656e-11 * f
        let h2 = Float(h2a + (h2b - h2c))

        let magnitude = Double((h1 * h1 + h2 * h2).squareRoot())
        guard magnitude > 0 else { return 0 }
        return Float(f * 1.0130572010774149e-03 / magnitude)
    }
}

/// The frame-by-frame state behind the textures, as Plexamp's `VisualizerHost` keeps it.
///
/// Three stages, every frame, in this order:
///
/// 1. **Level** per band, with gravity: a new high is taken at once; below it, the level
///    falls by `t² × 0.4`, `t` being frames since that high. So it holds for exactly the
///    frame after a rise and then meets the music. 100 frames after the last high the
///    fall stops, and the level stays put until the music exceeds it again — which looks
///    like an oversight in the original, and is kept, because it is how Plexamp moves.
/// 2. **Smoothed** = level × alpha + smoothed × (1 − alpha). This is what row 0 of the
///    frequency texture holds — the "amplitude" every shader reads.
/// 3. **Peak** per band, the same hold-and-fall over the smoothed value but much slower
///    (`t² × 0.00005`), in row 1. Only for programs that ask for peaks.
///
/// History, for the programs that want it, is the smoothed row written into a 32-row
/// ring every second frame.
///
/// The original ticks once per `requestAnimationFrame`, so these rates are per 60 Hz
/// frame; the renderer runs at 60 to match.
struct VisualizerHostState: Sendable {
    static let bands = VisualizerSpectrum.bandCount
    static let historyRows = 32

    private static let holdFrames = 100
    private static let levelGravity: Float = 0.4
    private static let peakHoldFrames = 100
    private static let peakGravity: Float = 0.0001

    private var levels = [Float](repeating: 0, count: bands)
    private var levelHolds = [Int](repeating: 0, count: bands)
    private var peakHolds = [Int](repeating: 0, count: bands)

    /// 64 smoothed amplitudes then 64 peaks: the frequency texture's two rows, as-is.
    private(set) var frequencyTexels = [Float](repeating: 0, count: bands * 2)
    /// 32 rows of 64, the ring the history programs walk backwards through.
    private(set) var historyTexels = [Float](repeating: 0, count: bands * historyRows)
    /// The row written last, or -1 before the first.
    private(set) var historyIndex = -1
    private var historyTicks = -1

    init() {}

    /// What `VisualizerHost::setVisualizer` clears when a program is chosen: history for
    /// a program without it, the levels for one that reads no spectrum. The smoothed
    /// values and peaks carry over, as they do in Plexamp.
    mutating func select(_ data: VisualizerData) {
        if !data.frequencyHistory {
            historyTexels = [Float](repeating: 0, count: Self.bands * Self.historyRows)
            historyIndex = -1
            historyTicks = -1
        } else if !data.frequency {
            levels = [Float](repeating: 0, count: Self.bands)
            levelHolds = [Int](repeating: 0, count: Self.bands)
        }
    }

    /// One frame, given this frame's 64 band levels.
    mutating func tick(bands: [Float], data: VisualizerData) {
        guard data.wantsSpectrum, bands.count == Self.bands else { return }
        let count = Self.bands

        for index in 0..<count {
            let value = bands[index]
            if levels[index] < value {
                levels[index] = value
                levelHolds[index] = Self.holdFrames
            } else if levelHolds[index] > 0 {
                let t = Float(Self.holdFrames - levelHolds[index])
                levels[index] = max(value, levels[index] - t * t * Self.levelGravity)
                levelHolds[index] -= 1
            }
        }

        let alpha = data.alpha
        for index in 0..<count {
            frequencyTexels[index] = Float(
                Double(levels[index] * alpha) + Double(frequencyTexels[index]) * (1 - Double(alpha))
            )
        }

        if data.peaks {
            for index in 0..<count {
                let smoothed = frequencyTexels[index]
                let peak = count + index
                if frequencyTexels[peak] < smoothed {
                    frequencyTexels[peak] = smoothed
                    peakHolds[index] = Self.peakHoldFrames
                } else if peakHolds[index] > 0 {
                    let t = Double(Self.peakHoldFrames - peakHolds[index])
                    let fallen = Float(Double(frequencyTexels[peak]) - Double(Self.peakGravity) * 0.5 * t * t)
                    frequencyTexels[peak] = max(smoothed, fallen)
                    peakHolds[index] -= 1
                }
            }
        }

        if data.frequencyHistory {
            historyTicks += 1
            if historyTicks & 1 == 0 {
                historyIndex = (historyIndex + 1) % Self.historyRows
                let row = historyIndex * count
                for index in 0..<count {
                    historyTexels[row + index] = frequencyTexels[index]
                }
            }
        }
    }
}

/// The palette/loudness crossfade: 60 frames from the previous track's row to the new
/// one, eased by the shaders with a cubic-out. 1 means "settled on the new row".
struct VisualizerCrossfade: Sendable {
    private static let frames = 60
    private var frame = -1

    var value: Float { frame < 0 ? 1 : Float(frame) / Float(Self.frames) }

    /// A second start mid-fade is ignored, as in Plexamp: the fade already running
    /// arrives at the newest row anyway.
    mutating func start() {
        guard frame == -1 else { return }
        frame = 0
    }

    mutating func advance() {
        guard frame >= 0 else { return }
        frame = frame == Self.frames ? -1 : frame + 1
    }
}

/// The track's loudness over its length, for the visualisers that draw the whole track
/// (Soundprint). A port of `VisualizerHost::ProcessLoudnessData` and `updateLoudness`.
enum VisualizerLoudness {
    static let texels = 128

    /// LUFS-style readings in, 128 texels out, 0...~0.82.
    ///
    /// Each reading below −35 counts as silence; above it, `x = (v + 35) × 20/7` is
    /// squared over 100 and scaled by 1.5, so the loud end is stretched. The result is
    /// normalised so the loudest point is 40.9, resampled to 128 when there are fewer,
    /// and divided by 50 on the way into the texture.
    static func texels(from readings: [Float]) -> [Float] {
        guard !readings.isEmpty else { return [] }

        var values = readings.map { reading -> Float in
            guard reading >= -35 else { return 0 }
            let x = (reading + 35) * 2.857142925262451
            let value = x * (x / 100) * 1.5
            return value.isNaN ? 0 : value
        }

        if let loudest = values.max(), loudest != 0 {
            let scale = 40.909088134765625 / loudest
            for index in values.indices { values[index] *= scale }
        }

        if values.count < texels {
            values = interpolate(values, count: texels)
        }

        var texels = [Float](repeating: 0, count: Self.texels)
        for index in 0..<min(values.count, Self.texels) {
            texels[index] = values[index] / 50
        }
        return texels
    }

    /// `Utils::Interpolate`: linear resampling that keeps both ends exactly. One value
    /// in gives zeros out — the original's quirk, harmless since a track has many.
    static func interpolate(_ values: [Float], count: Int) -> [Float] {
        var output = [Float](repeating: 0, count: count)
        guard values.count > 1, count > 0 else { return output }

        output[0] = values[0]
        let last = count - 1
        if last > 1 {
            let step = Float(values.count - 1) / Float(last)
            for index in 1..<last {
                let position = Float(index) * step
                let low = Int(position.rounded(.down))
                let high = Int(position.rounded(.up))
                output[index] = (position - Float(low)) * (values[high] - values[low]) + values[low]
            }
        }
        if last > 0 { output[last] = values[values.count - 1] }
        return output
    }
}
