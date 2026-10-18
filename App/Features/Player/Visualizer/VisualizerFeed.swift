import Accelerate
import Foundation

/// BASS's `BASS_DATA_FFT512 | BASS_DATA_FFT_REMOVEDC`, which is what Plexamp asks of its
/// engine: the newest 512 samples, the mean taken out, a Hann window, and 256 magnitudes
/// scaled so that a full-scale sine reads about 0.5 (1.0 before the window halves it).
///
/// Its own type rather than part of the feed because a `@MainActor` class cannot free
/// non-`Sendable` storage in `deinit` under strict concurrency.
private final class VisualizerFFT: @unchecked Sendable {
    static let size = VisualizerSpectrum.fftSize
    private static let half = size / 2
    private let log2n = vDSP_Length(9)
    private let setup: FFTSetup?

    private let window: UnsafeMutablePointer<Float>
    private let windowed: UnsafeMutablePointer<Float>
    private let realp: UnsafeMutablePointer<Float>
    private let imagp: UnsafeMutablePointer<Float>

    init() {
        window = .allocate(capacity: Self.size)
        windowed = .allocate(capacity: Self.size)
        realp = .allocate(capacity: Self.half)
        imagp = .allocate(capacity: Self.half)
        // The plain 0.5 − 0.5·cos window, not vDSP's energy-normalised one: BASS's
        // scaling assumes a window whose peak is 1.
        window.initialize(repeating: 0, count: Self.size)
        vDSP_hann_window(window, vDSP_Length(Self.size), Int32(vDSP_HANN_DENORM))
        windowed.initialize(repeating: 0, count: Self.size)
        realp.initialize(repeating: 0, count: Self.half)
        imagp.initialize(repeating: 0, count: Self.half)
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
    }

    deinit {
        if let setup { vDSP_destroy_fftsetup(setup) }
        window.deallocate()
        windowed.deallocate()
        realp.deallocate()
        imagp.deallocate()
    }

    /// `samples` is the whole ring, oldest first; the last 512 are used.
    func magnitudes(of samples: [Float], into output: inout [Float]) {
        guard let setup, samples.count >= Self.size, output.count == Self.half else { return }

        samples.withUnsafeBufferPointer { input in
            guard let base = input.baseAddress else { return }
            let newest = base + (samples.count - Self.size)
            var mean: Float = 0
            vDSP_meanv(newest, 1, &mean, vDSP_Length(Self.size))
            var negated = -mean
            vDSP_vsadd(newest, 1, &negated, windowed, 1, vDSP_Length(Self.size))
            vDSP_vmul(windowed, 1, window, 1, windowed, 1, vDSP_Length(Self.size))
        }

        var split = DSPSplitComplex(realp: realp, imagp: imagp)
        windowed.withMemoryRebound(to: DSPComplex.self, capacity: Self.half) { typed in
            vDSP_ctoz(typed, 2, &split, 1, vDSP_Length(Self.half))
        }
        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))

        output.withUnsafeMutableBufferPointer { out in
            guard let base = out.baseAddress else { return }
            vDSP_zvabs(&split, 1, base, 1, vDSP_Length(Self.half))
            // zrip's forward result is twice the DFT, so |X|·2/N is |zrip|/N.
            var scale = 1 / Float(Self.size)
            vDSP_vsmul(base, 1, &scale, base, 1, vDSP_Length(Self.half))
            // Bin 0 holds DC and Nyquist packed together; the bands never read it.
            base[0] = 0
        }
    }
}

/// Everything the visualiser textures hold, kept current one frame at a time: Plexamp's
/// `VisualizerHost`, driven by our sample ring instead of BASS.
///
/// One for the app, so the colours and the motion carry over when the player is closed
/// and opened again, as Plexamp's singleton host's do. The very first show fades in from
/// black over a second, because the palette starts empty, which is also Plexamp's.
@MainActor
final class VisualizerFeed {
    private static var instance: VisualizerFeed?

    static func shared(buffer: AudioSampleBuffer) -> VisualizerFeed {
        if let instance { return instance }
        let feed = VisualizerFeed(buffer: buffer)
        instance = feed
        return feed
    }

    /// Read once a frame, outside any view body, so its 4 Hz ticks invalidate nothing.
    weak var player: PlaybackController?

    private let buffer: AudioSampleBuffer
    private let fft = VisualizerFFT()
    private var samples = [Float](repeating: 0, count: AudioSampleBuffer.capacity)
    private var magnitudes = [Float](repeating: 0, count: VisualizerSpectrum.binCount)
    private var bands = [Float](repeating: 0, count: VisualizerSpectrum.bandCount)

    private(set) var host = VisualizerHostState()
    private var crossfade = VisualizerCrossfade()
    private var data = VisualizerData()

    /// 32 RGBA texels per row, row 0 this track's and row 1 the last's. Alpha is zero,
    /// as in Plexamp; the shaders only read colour.
    private(set) var paletteTexels = [UInt8](repeating: 0, count: VisualizerPalette.size * 2 * 4)
    /// 128 per row, the same two rows.
    private(set) var loudnessTexels = [Float](repeating: 0, count: VisualizerLoudness.texels * 2)

    private(set) var crossfadeValue: Float = 1
    /// Percent through the track, whole numbers, as Plexamp's engine reports it.
    private(set) var progress: Float = 0

    private init(buffer: AudioSampleBuffer) {
        self.buffer = buffer
    }

    func select(_ program: VisualizerProgram) {
        guard program.data != data else { return }
        data = program.data
        host.select(data)
    }

    /// A new track's colours: the old row moves down and the fade starts.
    func setPalette(_ colours: [VisualizerPalette.RGB]) {
        guard colours.count == VisualizerPalette.size else { return }
        let row = VisualizerPalette.size * 4
        for index in 0..<row { paletteTexels[row + index] = paletteTexels[index] }
        for (index, colour) in colours.enumerated() {
            paletteTexels[index * 4] = UInt8(clamping: Int(colour.r))
            paletteTexels[index * 4 + 1] = UInt8(clamping: Int(colour.g))
            paletteTexels[index * 4 + 2] = UInt8(clamping: Int(colour.b))
            paletteTexels[index * 4 + 3] = 0
        }
        crossfade.start()
    }

    func setLoudness(_ texels: [Float]) {
        let row = VisualizerLoudness.texels
        guard texels.count == row else { return }
        for index in 0..<row {
            loudnessTexels[row + index] = loudnessTexels[index]
            loudnessTexels[index] = texels[index]
        }
        crossfade.start()
    }

    /// One frame: what `VisualizerHost::tick` does per `requestAnimationFrame`.
    func tick() {
        if data.wantsSpectrum {
            // Paused, Plexamp's engine reads nothing and the bands fall to zero; the
            // ring here would otherwise hold the last moment before the pause forever.
            if player?.isPlaying == true {
                buffer.snapshot(into: &samples)
                fft.magnitudes(of: samples, into: &magnitudes)
            } else {
                for index in magnitudes.indices { magnitudes[index] = 0 }
            }
            VisualizerSpectrum.bands(
                magnitudes: magnitudes,
                sampleRate: Int(buffer.sampleRate),
                into: &bands
            )
            host.tick(bands: bands, data: data)
        }

        if let player, player.duration > 0 {
            progress = Float((player.elapsed / player.duration * 100).rounded())
        } else {
            progress = 0
        }

        crossfade.advance()
        crossfadeValue = crossfade.value
    }
}
