import Foundation
import Synchronization

/// The signal processing behind Loudness Leveling, the equaliser, the limiter and Sweet
/// Fades — Plexamp's audio chain, rebuilt.
///
/// Foundation-only and compiled into the test package, because none of this can be
/// heard from CI: a sign error in a filter coefficient is a test failure here or a
/// ruined album on the phone, with nothing in between.
///
/// Two rules for everything the real-time thread calls (`DSPChain.process`): it never
/// allocates and it never waits. Storage is allocated once in `init`, parameters arrive
/// through `withLockIfAvailable` — which gives up rather than blocks — and the maths is
/// plain arithmetic on preallocated memory.
enum Decibels {
    static func linear(_ decibels: Float) -> Float {
        powf(10, decibels / 20)
    }

    static func linear(_ decibels: Double) -> Double {
        pow(10, decibels / 20)
    }

    static func from(linear value: Double) -> Double {
        value > 0 ? 20 * log10(value) : -.infinity
    }
}

// MARK: - Loudness Leveling

/// Plexamp's volume normalisation: the album's ReplayGain plus a preamp.
///
/// Read from Plexamp's own player: it takes the stream's **album** gain whenever
/// leveling is on, and nothing at all — not even the preamp — when the track has no
/// gain data or leveling is off. Album rather than track gain is the right call for
/// albums and the less wrong one for everything else: a quiet interlude stays quiet
/// relative to the songs around it, instead of being pulled up to their level.
///
/// The one addition here: Navidrome reports track gain alone for a file whose album
/// was never analysed as a whole, so that is the fallback rather than nothing.
enum LoudnessLeveling {
    /// ReplayGain 2.0's reference. Gains are decibels *to* this level.
    static let referenceLUFS = -18.0
    /// Plexamp's default: "+4 dB from the reference", i.e. aim for −14 LUFS, which is
    /// where most streaming services normalise and where most people expect volume to be.
    static let defaultPreamp = 4.0
    static let preampOptions: [Double] = [6, 5, 4, 3, 2, 1, 0]

    /// Decibels to apply to one track, or nil for "leave it alone".
    ///
    /// Without the limiter, the gain is also capped so the track's own peak cannot clip:
    /// the limiter is what makes a +4 dB preamp safe on a quiet master with sharp
    /// transients, and turning it off has to fall back to something that cannot distort.
    static func gain(
        for replayGain: ReplayGain?,
        isEnabled: Bool,
        preamp: Double,
        limiter: Bool
    ) -> Double? {
        guard isEnabled, let replayGain,
              let base = replayGain.albumGain ?? replayGain.trackGain
        else { return nil }

        var gain = base + (replayGain.baseGain ?? 0) + preamp

        if !limiter, let peak = replayGain.albumPeak ?? replayGain.trackPeak, peak > 0 {
            gain = min(gain, -Decibels.from(linear: peak))
        }
        return gain
    }

    /// A track's integrated loudness, recovered from its gain. The inverse of how the
    /// gain was computed: −18 LUFS minus the decibels it takes to get there.
    static func loudness(of replayGain: ReplayGain?) -> Double? {
        guard let gain = replayGain?.trackGain ?? replayGain?.albumGain else { return nil }
        return referenceLUFS - gain
    }
}

// MARK: - Filters

/// One second-order section, normalised so `a0 == 1`.
///
/// Designs are Robert Bristow-Johnson's "Audio EQ Cookbook", which is what nearly every
/// parametric EQ — `AVAudioUnitEQ` and the BASS library Plexamp uses included — is built
/// from, so a preset means the same thing here as it does there.
struct Biquad: Equatable, Sendable {
    var b0: Float = 1
    var b1: Float = 0
    var b2: Float = 0
    var a1: Float = 0
    var a2: Float = 0

    static let identity = Biquad()

    var isIdentity: Bool { self == .identity }

    /// A bell around `frequency`, `octaves` wide at its half-gain points.
    static func peaking(
        frequency: Double,
        gain decibels: Double,
        octaves: Double,
        sampleRate: Double
    ) -> Biquad {
        // A band at or past Nyquist cannot be built, and one just below it is unstable in
        // practice. At 32 kHz the 16 kHz band would be exactly that, so it simply drops out.
        guard abs(decibels) > 0.001, sampleRate > 0, frequency < sampleRate * 0.45 else {
            return .identity
        }

        let a = pow(10, decibels / 40)
        let w0 = 2 * Double.pi * frequency / sampleRate
        let sinW0 = sin(w0)
        let alpha = sinW0 * sinh(log(2) / 2 * octaves * w0 / sinW0)
        let cosW0 = cos(w0)

        return normalised(
            b0: 1 + alpha * a, b1: -2 * cosW0, b2: 1 - alpha * a,
            a0: 1 + alpha / a, a1: -2 * cosW0, a2: 1 - alpha / a
        )
    }

    static func highShelf(
        frequency: Double,
        gain decibels: Double,
        q: Double,
        sampleRate: Double
    ) -> Biquad {
        let a = pow(10, decibels / 40)
        let w0 = 2 * Double.pi * frequency / sampleRate
        let cosW0 = cos(w0)
        let alpha = sin(w0) / (2 * q)
        let root = 2 * sqrt(a) * alpha

        return normalised(
            b0: a * ((a + 1) + (a - 1) * cosW0 + root),
            b1: -2 * a * ((a - 1) + (a + 1) * cosW0),
            b2: a * ((a + 1) + (a - 1) * cosW0 - root),
            a0: (a + 1) - (a - 1) * cosW0 + root,
            a1: 2 * ((a - 1) - (a + 1) * cosW0),
            a2: (a + 1) - (a - 1) * cosW0 - root
        )
    }

    static func highPass(frequency: Double, q: Double, sampleRate: Double) -> Biquad {
        let w0 = 2 * Double.pi * frequency / sampleRate
        let cosW0 = cos(w0)
        let alpha = sin(w0) / (2 * q)

        return normalised(
            b0: (1 + cosW0) / 2, b1: -(1 + cosW0), b2: (1 + cosW0) / 2,
            a0: 1 + alpha, a1: -2 * cosW0, a2: 1 - alpha
        )
    }

    private static func normalised(
        b0: Double, b1: Double, b2: Double,
        a0: Double, a1: Double, a2: Double
    ) -> Biquad {
        Biquad(
            b0: Float(b0 / a0), b1: Float(b1 / a0), b2: Float(b2 / a0),
            a1: Float(a1 / a0), a2: Float(a2 / a0)
        )
    }

    /// Magnitude response in decibels at one frequency. For tests and for drawing the
    /// curve; never called on the audio thread.
    func response(at frequency: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * frequency / sampleRate
        let (c1, s1, c2, s2) = (cos(w), sin(w), cos(2 * w), sin(2 * w))
        let numRe = Double(b0) + Double(b1) * c1 + Double(b2) * c2
        let numIm = -(Double(b1) * s1 + Double(b2) * s2)
        let denRe = 1 + Double(a1) * c1 + Double(a2) * c2
        let denIm = -(Double(a1) * s1 + Double(a2) * s2)
        let magnitude = sqrt((numRe * numRe + numIm * numIm) / (denRe * denRe + denIm * denIm))
        return Decibels.from(linear: magnitude)
    }
}

// MARK: - Equaliser

/// Plexamp's equaliser: ten octave bands, the classic graphic-EQ layout.
enum Equalizer {
    /// Read from Plexamp's own band table.
    static let frequencies: [Double] = [31.25, 62.5, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000]
    static let bandCount = 10
    static let labels = ["31", "63", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]
    static let gainRange: ClosedRange<Float> = -12...12
    /// One octave per band, so neighbouring bells meet at their half-gain points and a
    /// row of equal boosts sums to a near-flat shelf rather than a comb. It is also the
    /// Q of 1.41 that AutoEQ's ten-band headphone corrections are computed for.
    static let bandwidthOctaves = 1.0

    /// Carries a curve set on different bands over to these ten, by interpolating on a
    /// log-frequency axis and holding the end values flat beyond the old range.
    ///
    /// For the five-band EQ this app used to have, so an existing curve survives the
    /// change instead of resetting — the same thing Plexamp does when its band count
    /// changes.
    static func resample(_ gains: [Float], from source: [Double]) -> [Float] {
        guard gains.count == source.count, let first = gains.first, let last = gains.last else {
            return Array(repeating: 0, count: bandCount)
        }
        let points = zip(source.map(log2), gains).sorted { $0.0 < $1.0 }

        return frequencies.map { frequency in
            let x = log2(frequency)
            guard let upper = points.firstIndex(where: { $0.0 >= x }) else { return last }
            guard upper > 0 else { return first }
            let (x0, y0) = points[upper - 1]
            let (x1, y1) = points[upper]
            let t = Float((x - x0) / (x1 - x0))
            return y0 + (y1 - y0) * t
        }
    }
}

/// Everything the audio thread needs to know about the user's settings, as one value.
///
/// A plain value with no references in it, so copying it out of the lock is a `memcpy`:
/// `SIMD16` holds the ten band gains inline, where an `Array` would mean a reference
/// count touched on the real-time thread.
struct DSPParameters: Equatable, Sendable {
    var loudnessLeveling = true
    var preamp = LoudnessLeveling.defaultPreamp
    var limiter = true
    var equalizer = false
    /// Decibels; the first `Equalizer.bandCount` lanes are used.
    var bands = SIMD16<Float>(repeating: 0)
    /// Applied with the EQ, so a preset that boosts everything can be pulled back down.
    var equalizerPreamp: Float = 0

    /// Bumped on every change, so a processor can tell "new settings" from "same settings
    /// read again" with one integer compare.
    var generation: UInt64 = 0

    var isEqualizerFlat: Bool {
        guard equalizer else { return true }
        for index in 0..<Equalizer.bandCount where abs(bands[index]) > 0.001 { return false }
        return abs(equalizerPreamp) < 0.001
    }
}

/// The one place settings cross from the main thread to the audio thread.
///
/// A `Mutex`, read with `withLockIfAvailable`: the audio thread never blocks on it. If
/// the main thread happens to be mid-write, that buffer of audio is processed with the
/// previous settings and the next one picks the new ones up, five milliseconds later.
final class DSPSettingsStore: Sendable {
    private let state = Mutex(DSPParameters())

    func update(_ change: (inout DSPParameters) -> Void) {
        state.withLock { parameters in
            change(&parameters)
            parameters.generation &+= 1
        }
    }

    var current: DSPParameters {
        state.withLock { $0 }
    }

    /// Real-time safe. Nil when the lock is held by a writer.
    func readIfAvailable() -> DSPParameters? {
        state.withLockIfAvailable { $0 }
    }
}

/// One track's processing: gain, then EQ, then limiter.
///
/// One instance per playing item, owned by its tap, because the gain is per track and
/// filter state belongs to one continuous signal. Not `Sendable` in any meaningful sense
/// — it is created on one thread and then used only by the audio thread — hence
/// `@unchecked`, stated rather than hidden.
final class DSPChain: @unchecked Sendable {
    static let maximumChannels = 8

    let replayGain: ReplayGain?
    private let settings: DSPSettingsStore

    private(set) var sampleRate: Double = 44_100
    private var channelCount = 2

    private var parameters = DSPParameters()
    private var appliedGeneration: UInt64 = .max

    /// The gain the current buffer ends at, and the one it is ramping towards. Ramped
    /// rather than stepped, because a sudden 6 dB jump mid-song is a click.
    private var currentGain: Float = 1
    private var targetGain: Float = 1
    private var hasStarted = false

    private var coefficients: UnsafeMutablePointer<Biquad>
    private var activeBands = 0
    /// Two delay elements per band per channel, transposed direct form II.
    private var state: UnsafeMutablePointer<Float>
    private var limiterActive = false
    private var limiterGain: Float = 1

    /// −1 dBFS: headroom for the inter-sample peaks a DAC reconstructs between samples.
    static let limiterCeiling: Float = 0.891
    /// About 60 ms to recover from a peak. Fast enough not to duck a whole bar, slow
    /// enough not to pump on every kick drum.
    private var limiterRelease: Float = 0.9996

    init(replayGain: ReplayGain?, settings: DSPSettingsStore) {
        self.replayGain = replayGain
        self.settings = settings
        coefficients = .allocate(capacity: Equalizer.bandCount)
        coefficients.initialize(repeating: .identity, count: Equalizer.bandCount)
        let stateCount = Self.maximumChannels * Equalizer.bandCount * 2
        state = .allocate(capacity: stateCount)
        state.initialize(repeating: 0, count: stateCount)
    }

    deinit {
        coefficients.deinitialize(count: Equalizer.bandCount)
        coefficients.deallocate()
        state.deinitialize(count: Self.maximumChannels * Equalizer.bandCount * 2)
        state.deallocate()
    }

    /// Called before the first buffer, and again whenever the format changes. Resets the
    /// filters, since their memory belongs to a signal that has gone.
    func prepare(sampleRate: Double, channels: Int) {
        self.sampleRate = sampleRate > 0 ? sampleRate : 44_100
        channelCount = max(1, min(channels, Self.maximumChannels))
        state.update(repeating: 0, count: Self.maximumChannels * Equalizer.bandCount * 2)
        limiterRelease = Float(exp(-1 / (0.06 * self.sampleRate)))
        appliedGeneration = .max
        refreshParameters(force: true)
    }

    /// Picks up new settings if the lock is free. Recomputing ten biquads is a few dozen
    /// trig calls — microseconds — so doing it here, on change only, is fine.
    private func refreshParameters(force: Bool = false) {
        let latest = force ? settings.current : settings.readIfAvailable()
        guard let latest, latest.generation != appliedGeneration else { return }
        appliedGeneration = latest.generation
        parameters = latest

        let gainDB = LoudnessLeveling.gain(
            for: replayGain,
            isEnabled: latest.loudnessLeveling,
            preamp: latest.preamp,
            limiter: latest.limiter
        ) ?? 0
        let eqPreamp = latest.isEqualizerFlat ? 0 : Double(latest.equalizerPreamp)
        targetGain = Decibels.linear(Float(gainDB + eqPreamp))
        if !hasStarted { currentGain = targetGain }

        // Plexamp only offers the limiter alongside leveling, since leveling is what
        // pushes a signal towards full scale; an EQ boost does too, so it counts.
        limiterActive = latest.limiter && (latest.loudnessLeveling || !latest.isEqualizerFlat)

        activeBands = 0
        if !latest.isEqualizerFlat {
            for index in 0..<Equalizer.bandCount {
                let filter = Biquad.peaking(
                    frequency: Equalizer.frequencies[index],
                    gain: Double(latest.bands[index]),
                    octaves: Equalizer.bandwidthOctaves,
                    sampleRate: sampleRate
                )
                if !filter.isIdentity {
                    coefficients[activeBands] = filter
                    activeBands += 1
                }
            }
        }
    }

    /// Processes non-interleaved channels in place. Real-time safe.
    func process(_ channels: UnsafeMutableBufferPointer<UnsafeMutablePointer<Float>>, frames: Int) {
        guard frames > 0, !channels.isEmpty else { return }
        refreshParameters()
        let count = min(channels.count, Self.maximumChannels)

        // Gain, ramped linearly across this buffer when it changed.
        let start = currentGain
        let end = targetGain
        if abs(start - end) > 0.0001 || abs(end - 1) > 0.0001 {
            let step = (end - start) / Float(frames)
            for channel in 0..<count {
                let samples = channels[channel]
                var gain = start
                for frame in 0..<frames {
                    gain += step
                    samples[frame] *= gain
                }
            }
        }
        currentGain = end
        hasStarted = true

        if activeBands > 0 {
            for channel in 0..<count {
                filter(channels[channel], frames: frames, channel: channel)
            }
        }

        if limiterActive {
            limit(channels, count: count, frames: frames)
        }
    }

    /// Processes one interleaved buffer in place, for the rare decoder that delivers one.
    /// Real-time safe: filters each channel by striding rather than copying out.
    func processInterleaved(_ samples: UnsafeMutablePointer<Float>, channels: Int, frames: Int) {
        guard frames > 0, channels > 0 else { return }
        refreshParameters()
        let count = min(channels, Self.maximumChannels)

        let start = currentGain
        let end = targetGain
        let step = (end - start) / Float(frames)
        if abs(start - end) > 0.0001 || abs(end - 1) > 0.0001 {
            var gain = start
            for frame in 0..<frames {
                gain += step
                for channel in 0..<channels { samples[frame * channels + channel] *= gain }
            }
        }
        currentGain = end
        hasStarted = true

        if activeBands > 0 {
            for channel in 0..<count {
                for band in 0..<activeBands {
                    let c = coefficients[band]
                    let z = state + (channel * Equalizer.bandCount + band) * 2
                    var z1 = z[0], z2 = z[1]
                    for frame in 0..<frames {
                        let index = frame * channels + channel
                        let x = samples[index]
                        let y = c.b0 * x + z1
                        z1 = c.b1 * x - c.a1 * y + z2
                        z2 = c.b2 * x - c.a2 * y
                        samples[index] = y
                    }
                    z[0] = z1
                    z[1] = z2
                }
            }
        }

        if limiterActive {
            var gain = limiterGain
            for frame in 0..<frames {
                var peak: Float = 0
                for channel in 0..<channels { peak = max(peak, abs(samples[frame * channels + channel])) }
                gain = limiterStep(peak: peak, gain: gain)
                if gain < 1 {
                    for channel in 0..<channels { samples[frame * channels + channel] *= gain }
                }
            }
            limiterGain = gain
        }
    }

    private func filter(_ samples: UnsafeMutablePointer<Float>, frames: Int, channel: Int) {
        for band in 0..<activeBands {
            let c = coefficients[band]
            let z = state + (channel * Equalizer.bandCount + band) * 2
            var z1 = z[0], z2 = z[1]
            for frame in 0..<frames {
                let x = samples[frame]
                let y = c.b0 * x + z1
                z1 = c.b1 * x - c.a1 * y + z2
                z2 = c.b2 * x - c.a2 * y
                samples[frame] = y
            }
            // Denormals are slow on some cores and inaudible on all of them.
            z[0] = abs(z1) < 1e-20 ? 0 : z1
            z[1] = abs(z2) < 1e-20 ? 0 : z2
        }
    }

    /// Instant attack, smooth release: no sample ever leaves above the ceiling, and the
    /// gain recovers over ~60 ms instead of snapping back.
    private func limit(
        _ channels: UnsafeMutableBufferPointer<UnsafeMutablePointer<Float>>,
        count: Int,
        frames: Int
    ) {
        var gain = limiterGain
        for frame in 0..<frames {
            var peak: Float = 0
            for channel in 0..<count { peak = max(peak, abs(channels[channel][frame])) }
            gain = limiterStep(peak: peak, gain: gain)
            if gain < 1 {
                for channel in 0..<count { channels[channel][frame] *= gain }
            }
        }
        limiterGain = gain
    }

    @inline(__always)
    private func limiterStep(peak: Float, gain: Float) -> Float {
        // Release towards unity...
        var next = 1 - (1 - gain) * limiterRelease
        // ...but never let this sample out over the ceiling.
        if peak * next > Self.limiterCeiling {
            next = Self.limiterCeiling / peak
        }
        return next
    }
}

// MARK: - Loudness measurement

/// Momentary loudness, after ITU-R BS.1770: K-weighted, 400 ms windows, measured every
/// 100 ms. What Sweet Fades reads a track's intro and outro with.
///
/// K-weighting is two filters — a shelf that adds 4 dB above ~1.5 kHz, roughly how the
/// head boosts presence, and a high-pass that ignores sub-bass — and it is what makes the
/// numbers LUFS rather than plain RMS, and so comparable with the server's ReplayGain.
enum LoudnessMeter {
    static let window = 0.4
    static let hop = 0.1

    /// One value per hop, in LUFS. `channels` are equal-length, non-interleaved.
    static func momentary(channels: [[Float]], sampleRate: Double) -> [Float] {
        guard var meter = MomentaryLoudness(sampleRate: sampleRate, channels: channels.count) else { return [] }
        meter.add(channels)
        return meter.finish()
    }

    /// Gated integrated loudness of whatever was measured: BS.1770's −70 LUFS absolute
    /// gate, then a −10 LU relative one. Over a track's first and last seconds rather
    /// than the whole thing, it is an estimate — used only when the server has no gain.
    static func integrated(_ levels: [Float]) -> Double? {
        let audible = levels.filter { $0 > -70 }
        guard !audible.isEmpty else { return nil }
        let meanPower = audible.reduce(0.0) { $0 + pow(10, Double($1) / 10) } / Double(audible.count)
        let gate = 10 * log10(meanPower) - 10
        let kept = audible.filter { Double($0) > gate }
        guard !kept.isEmpty else { return nil }
        let keptPower = kept.reduce(0.0) { $0 + pow(10, Double($1) / 10) } / Double(kept.count)
        return 10 * log10(keptPower)
    }
}

/// `LoudnessMeter.momentary` a block at a time, so a whole track can be measured in the
/// memory of one block rather than of the whole file: the seekbar draws a track's
/// momentary loudness from its first second to its last.
///
/// Fed in one piece or in many, the readings are the same, to the bit.
struct MomentaryLoudness {
    private let shelf: Biquad
    private let highPass: Biquad
    private let windowFrames: Int
    private let hopFrames: Int
    /// Each channel's filter state, carried from one block into the next.
    private var state: [(Float, Float, Float, Float)]
    /// Weighted power summed since the first frame, so a window is one subtraction.
    private var total: Double = 0
    private var frames = 0
    private var nextStart = 0
    /// Windows begun and not yet full: where each starts, and the total there.
    private var open: [(start: Int, total: Double)] = []
    /// One block's weighted power, kept between blocks to save reallocating it.
    private var power: [Double] = []
    private var levels: [Float] = []

    /// Nil for no channels or no sample rate, which measure nothing.
    init?(sampleRate: Double, channels: Int) {
        guard sampleRate > 0, channels > 0 else { return nil }
        shelf = Biquad.highShelf(frequency: 1_500, gain: 4, q: 1 / 2.squareRoot(), sampleRate: sampleRate)
        highPass = Biquad.highPass(frequency: 38, q: 0.5, sampleRate: sampleRate)
        windowFrames = max(1, Int(LoudnessMeter.window * sampleRate))
        hopFrames = max(1, Int(LoudnessMeter.hop * sampleRate))
        state = Array(repeating: (0, 0, 0, 0), count: channels)
    }

    /// The next frames of every channel, equal-length and non-interleaved.
    mutating func add(_ channels: [[Float]]) {
        guard let length = channels.first?.count, length > 0 else { return }
        if power.count < length { power = [Double](repeating: 0, count: length) }
        for index in 0..<length { power[index] = 0 }

        // Squared, weighted samples summed across channels (equal channel weights: front
        // left and right, which is everything this app will meet).
        for (channel, samples) in channels.prefix(state.count).enumerated() {
            var z = state[channel]
            for index in 0..<min(length, samples.count) {
                let x = samples[index]
                let y1 = shelf.b0 * x + z.0
                z.0 = shelf.b1 * x - shelf.a1 * y1 + z.1
                z.1 = shelf.b2 * x - shelf.a2 * y1
                let y2 = highPass.b0 * y1 + z.2
                z.2 = highPass.b1 * y1 - highPass.a1 * y2 + z.3
                z.3 = highPass.b2 * y1 - highPass.a2 * y2
                power[index] += Double(y2 * y2)
            }
            state[channel] = z
        }

        for index in 0..<length {
            if frames == nextStart {
                open.append((frames, total))
                nextStart += hopFrames
            }
            total += power[index]
            frames += 1
            // Windows fill in the order they began, so only the oldest can be full.
            if let oldest = open.first, frames - oldest.start == windowFrames {
                close(oldest)
                open.removeFirst()
            }
        }
    }

    /// One value per hop, in LUFS. The last windows run past the end and are measured
    /// over what there is.
    mutating func finish() -> [Float] {
        for window in open { close(window) }
        open.removeAll()
        return levels
    }

    private mutating func close(_ window: (start: Int, total: Double)) {
        let mean = (total - window.total) / Double(frames - window.start)
        levels.append(Float(mean > 0 ? -0.691 + 10 * log10(mean) : -120))
    }
}

/// The loudness shape of a track's first or last seconds.
///
/// `levels` run forwards in time for an intro and **backwards from the end** for an
/// outro, so in both cases index 0 is the track boundary and "how long until the music
/// is properly going" is the same search.
struct LoudnessRamp: Codable, Hashable, Sendable {
    var levels: [Float]
    var hop: Double = LoudnessMeter.hop

    /// Seconds from the boundary until the level first reaches `threshold`, interpolated
    /// between measurements. Zero when it never does in the measured span — Plexamp's own
    /// answer for "no ramp", and the safe one: no overlap rather than a guessed one.
    func time(toReach threshold: Double) -> Double {
        let target = Float(threshold)
        for (index, level) in levels.enumerated() where level >= target {
            guard index > 0 else { return 0 }
            let previous = levels[index - 1]
            let fraction = previous < level ? Double((target - previous) / (level - previous)) : 0
            return (Double(index - 1) + min(max(fraction, 0), 1)) * hop
        }
        return 0
    }
}

// MARK: - Sweet Fades

/// Plexamp's Sweet Fades: crossfade every transition, except within an album played in
/// order, and make each overlap as long as the two tracks' own shapes allow.
///
/// Read from Plexamp's audio engine. For each pair it finds how long the outgoing track
/// spends winding down (its *end ramp*) and how long the incoming one takes to get going
/// (its *start ramp*), and starts the next track that much early: the outro's quiet tail
/// then lies under the intro's build, and the loud parts meet end to end. A song that
/// stops dead into one that starts dead overlaps by almost nothing; a long fade-out into
/// an ambient intro overlaps by up to fifteen seconds.
///
/// "Winding down" has a precise meaning there: below the track's own loudness plus 2 dB,
/// which is what Plexamp's `−16 − gain` works out to against a −18 LUFS reference.
enum SweetFades {
    /// Plexamp's cap, per ramp and on the total.
    static let maximumOverlap = 15.0
    /// Below this an overlap is indistinguishable from gapless, and gapless is what the
    /// player does better.
    static let minimumOverlap = 0.5

    /// Only analysed seconds can be searched; past these the music is assumed going.
    static let analysedSeconds = 15.0
    /// For a transition with nothing measured — the first track, or a stream that could
    /// not be cached in time. Short enough to be safe on anything, long enough to read
    /// as a fade rather than a glitch.
    static let fallbackOverlap = 3.0

    static func threshold(loudness: Double) -> Double {
        loudness + 2
    }

    /// Seconds the incoming track should start before the outgoing one ends, or nil when
    /// the transition should be gapless instead.
    static func overlap(
        outgoing: LoudnessRamp?,
        outgoingLoudness: Double?,
        incoming: LoudnessRamp?,
        incomingLoudness: Double?
    ) -> Double? {
        guard let outgoing, let incoming else { return nil }

        let outLoudness = outgoingLoudness ?? LoudnessMeter.integrated(outgoing.levels)
        let inLoudness = incomingLoudness ?? LoudnessMeter.integrated(incoming.levels)
        guard let outLoudness, let inLoudness else { return nil }

        let end = min(outgoing.time(toReach: threshold(loudness: outLoudness)), maximumOverlap)
        let start = min(incoming.time(toReach: threshold(loudness: inLoudness)), maximumOverlap)
        let total = min(end + start, maximumOverlap)
        return total >= minimumOverlap ? total : nil
    }

    /// True when `next` is the track that follows `current` on its album — the case
    /// Plexamp never fades, because the gap between two album tracks is the artist's.
    ///
    /// The same rule as Plexamp's consecutive-album check, applied per transition rather
    /// than to the whole queue, so a playlist that happens to contain a run of one album
    /// keeps that run gapless and still fades into whatever comes after it.
    static func isAlbumContinuation(from current: Song, to next: Song) -> Bool {
        guard let album = current.albumId, album == next.albumId else { return false }
        guard let track = current.track, let nextTrack = next.track else {
            // Same album with no numbering to go on: gapless is the safer mistake.
            return true
        }
        let disc = current.discNumber ?? 1
        let nextDisc = next.discNumber ?? 1
        if nextDisc == disc { return nextTrack == track + 1 }
        return nextDisc == disc + 1 && nextTrack == 1
    }
}
