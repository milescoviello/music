#if canImport(Accelerate)
import Accelerate
#endif
import Foundation
import Observation

#if canImport(Accelerate)
/// The FFT itself, and the buffers it needs.
///
/// Separate from `SpectrumAnalyser` for one concrete reason: a `@MainActor` class
/// cannot free non-`Sendable` storage in `deinit` under strict concurrency, so the
/// resources live on a type that is not actor-isolated and can therefore clean up after
/// itself instead of leaking for the life of the process.
private final class RealFFT: @unchecked Sendable {
    let size: Int
    private let half: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup?

    /// Separately allocated rather than being properties passed as `inout`, which is
    /// what keeps `DSPSplitComplex` from tripping Swift's exclusivity checks.
    private let realp: UnsafeMutablePointer<Float>
    private let imagp: UnsafeMutablePointer<Float>
    private let window: UnsafeMutablePointer<Float>
    private let windowed: UnsafeMutablePointer<Float>

    init(size: Int) {
        self.size = size
        half = size / 2
        log2n = vDSP_Length(log2(Double(size)).rounded())

        realp = .allocate(capacity: size / 2)
        imagp = .allocate(capacity: size / 2)
        window = .allocate(capacity: size)
        windowed = .allocate(capacity: size)
        realp.initialize(repeating: 0, count: size / 2)
        imagp.initialize(repeating: 0, count: size / 2)
        windowed.initialize(repeating: 0, count: size)

        // Hann, so the ring's arbitrary cut points do not ring across every band.
        window.initialize(repeating: 0, count: size)
        vDSP_hann_window(window, vDSP_Length(size), Int32(vDSP_HANN_NORM))

        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
    }

    deinit {
        if let setup { vDSP_destroy_fftsetup(setup) }
        realp.deallocate()
        imagp.deallocate()
        window.deallocate()
        windowed.deallocate()
    }

    /// Writes `size / 2` magnitudes for `samples`. Returns false if the setup failed.
    func magnitudes(of samples: [Float], into output: inout [Float]) -> Bool {
        guard let setup, samples.count == size, output.count == half else { return false }

        samples.withUnsafeBufferPointer { input in
            guard let base = input.baseAddress else { return }
            vDSP_vmul(base, 1, window, 1, windowed, 1, vDSP_Length(size))
        }

        var split = DSPSplitComplex(realp: realp, imagp: imagp)
        // The real signal is read as interleaved complex pairs -- that is what `ctoz`
        // is for, and it is the standard packing for a real-to-complex `zrip`.
        windowed.withMemoryRebound(to: DSPComplex.self, capacity: half) { typed in
            vDSP_ctoz(typed, 2, &split, 1, vDSP_Length(half))
        }

        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
        output.withUnsafeMutableBufferPointer { out in
            guard let base = out.baseAddress else { return }
            vDSP_zvabs(&split, 1, base, 1, vDSP_Length(half))
        }
        return true
    }
}
#endif

/// Turns the sample ring into a handful of band magnitudes, on the main actor.
///
/// The FFT deliberately runs *here* rather than in the audio callback. The callback's
/// only job is a `memcpy`; anything more on a real-time thread risks dropouts. Doing
/// the transform on a display-rate timer instead costs nothing audible and means the
/// maths can allocate, log and be reasoned about normally.
@MainActor
@Observable
final class SpectrumAnalyser {
    /// Bars on screen. 24 reads as a spectrum on a phone; 64 turns into a smear at this
    /// width, and 12 looks like a level meter.
    static let bandCount = 32

    /// Normalised 0...1 per band, already smoothed. What the view draws.
    private(set) var bands = [Float](repeating: 0, count: bandCount)
    /// Per-band high-water mark that hangs, then falls. Drawn as the cap above each bar.
    private(set) var peaks = [Float](repeating: 0, count: bandCount)
    /// True when audio is genuinely arriving, so the view can say "no signal" rather
    /// than implying silence.
    private(set) var isLive = false

    private let buffer: AudioSampleBuffer
    private let fft: RealFFT
    private let size = AudioSampleBuffer.capacity

    private var samples: [Float]
    private var magnitudes: [Float]

    /// Band edges in bin space, spaced logarithmically: linear bins put three quarters
    /// of the bars above 5 kHz, where there is nothing to see. Recomputed when the
    /// source rate changes, since the same bin means a different frequency at 48 kHz
    /// than at 96.
    private var bandRanges: [Range<Int>]
    private var mappedRate: Double = 0

    private var ticker: Task<Void, Never>?

    init(buffer: AudioSampleBuffer) {
        self.buffer = buffer
        fft = RealFFT(size: size)
        samples = [Float](repeating: 0, count: size)
        magnitudes = [Float](repeating: 0, count: size / 2)

        bandRanges = Self.ranges(forRate: 44_100, size: size)
        mappedRate = 44_100
    }

    /// Log-spaced band edges for a given sample rate.
    private static func ranges(forRate rate: Double, size: Int) -> [Range<Int>] {
        let nyquist = rate / 2
        let lowest = 40.0
        // Just under Nyquist, so the top band is never empty on a 44.1 kHz source.
        let highest = min(16_000.0, nyquist * 0.9)

        return (0..<bandCount).map { index in
            let low = lowest * pow(highest / lowest, Double(index) / Double(bandCount))
            let high = lowest * pow(highest / lowest, Double(index + 1) / Double(bandCount))
            let lowBin = max(1, Int(low / nyquist * Double(size / 2)))
            let highBin = min(size / 2, max(lowBin + 1, Int(high / nyquist * Double(size / 2))))
            return lowBin..<highBin
        }
    }

    /// Starts sampling at display rate. Only while a visualiser is actually on screen —
    /// an FFT nobody is looking at is pure battery.
    func start() {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                guard let self, !Task.isCancelled else { return }
                step()
            }
        }
    }

    func stop() {
        ticker?.cancel()
        ticker = nil
        // Fall to flat rather than freezing mid-bar.
        bands = [Float](repeating: 0, count: Self.bandCount)
        peaks = [Float](repeating: 0, count: Self.bandCount)
        isLive = false
    }

    private func step() {
        isLive = buffer.isReceiving

        let rate = buffer.sampleRate
        if abs(rate - mappedRate) > 1 {
            bandRanges = Self.ranges(forRate: rate, size: size)
            mappedRate = rate
        }

        buffer.snapshot(into: &samples)
        guard fft.magnitudes(of: samples, into: &magnitudes) else { return }

        var next = [Float](repeating: 0, count: Self.bandCount)
        for (index, range) in bandRanges.enumerated() {
            // Peak rather than mean across the band: an average washes out a narrow
            // strong tone, which is exactly what the eye wants to catch.
            var peak: Float = 0
            for bin in range where magnitudes[bin] > peak { peak = magnitudes[bin] }

            // Decibels, because linear magnitude puts everything in the bottom 5% of
            // the bar and music looks dead.
            let decibels = 20 * log10(max(peak, 1e-7) / Float(size))
            next[index] = min(max((decibels + 78) / 78, 0), 1)
        }

        // Asymmetric smoothing: attack fast so a snare registers, release slowly so the
        // bars fall like a real meter instead of flickering.
        for index in next.indices {
            let current = bands[index]
            let target = next[index]
            bands[index] = target > current
                ? current + (target - current) * 0.65
                : current + (target - current) * 0.14

            // The cap jumps to a new high instantly and then sinks, so a peak stays
            // legible for a moment after the bar beneath it has dropped away.
            peaks[index] = bands[index] > peaks[index]
                ? bands[index]
                : max(bands[index], peaks[index] - 0.012)
        }
    }
}
