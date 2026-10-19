import Foundation

/// BASS's `BASS_DATA_FFT512 | BASS_DATA_FFT_REMOVEDC`, as the phone's feed computes it
/// with Accelerate: the newest 512 samples, the mean taken out, a plain Hann window, and
/// 256 magnitudes scaled so a full-scale sine reads about 0.5. A radix-2 transform in
/// plain Swift: 512 points sixty times a second is nothing.
final class VisualizerFFT: @unchecked Sendable {
    static let size = VisualizerSpectrum.fftSize
    private static let half = size / 2
    private let window: [Float]
    private var real = [Float](repeating: 0, count: size)
    private var imaginary = [Float](repeating: 0, count: size)
    private let cosines: [Float]
    private let sines: [Float]
    private let reversed: [Int]

    init() {
        let size = Self.size
        window = (0..<size).map { 0.5 - 0.5 * cos(2 * .pi * Float($0) / Float(size)) }
        cosines = (0..<size / 2).map { cos(2 * .pi * Float($0) / Float(size)) }
        sines = (0..<size / 2).map { -sin(2 * .pi * Float($0) / Float(size)) }
        let bits = Int(log2(Double(size)))
        reversed = (0..<size).map { index in
            var value = 0
            for bit in 0..<bits where index & (1 << bit) != 0 { value |= 1 << (bits - 1 - bit) }
            return value
        }
    }

    /// `samples` is the whole ring, oldest first; the last 512 are used.
    func magnitudes(of samples: [Float], into output: inout [Float]) {
        let size = Self.size
        guard samples.count >= size, output.count == Self.half else { return }
        let base = samples.count - size
        var mean: Float = 0
        for index in 0..<size { mean += samples[base + index] }
        mean /= Float(size)
        for index in 0..<size {
            real[reversed[index]] = (samples[base + index] - mean) * window[index]
            imaginary[reversed[index]] = 0
        }
        var length = 2
        while length <= size {
            let stride = size / length
            for start in Swift.stride(from: 0, to: size, by: length) {
                for offset in 0..<length / 2 {
                    let wr = cosines[offset * stride]
                    let wi = sines[offset * stride]
                    let even = start + offset
                    let odd = even + length / 2
                    let tr = real[odd] * wr - imaginary[odd] * wi
                    let ti = real[odd] * wi + imaginary[odd] * wr
                    real[odd] = real[even] - tr
                    imaginary[odd] = imaginary[even] - ti
                    real[even] += tr
                    imaginary[even] += ti
                }
            }
            length *= 2
        }
        // |X|·2/N, as the phone's zrip-then-scale comes to.
        let scale = 2 / Float(size)
        for bin in 0..<Self.half {
            output[bin] = (real[bin] * real[bin] + imaginary[bin] * imaginary[bin]).squareRoot() * scale
        }
        output[0] = 0
    }
}

/// Everything the visualisers read, kept current one frame at a time: Plexamp's
/// `VisualizerHost`, driven by the mixer's sample ring. The phone's `VisualizerFeed`.
@MainActor
final class VisualizerFeed {
    private static var instance: VisualizerFeed?

    static func shared(buffer: AudioSampleBuffer) -> VisualizerFeed {
        if let instance { return instance }
        let feed = VisualizerFeed(buffer: buffer)
        instance = feed
        return feed
    }

    weak var player: PlaybackController?

    private let buffer: AudioSampleBuffer
    private let fft = VisualizerFFT()
    private var samples = [Float](repeating: 0, count: AudioSampleBuffer.capacity)
    private var magnitudes = [Float](repeating: 0, count: VisualizerSpectrum.binCount)
    private var bands = [Float](repeating: 0, count: VisualizerSpectrum.bandCount)
    private(set) var host = VisualizerHostState()
    private var crossfade = VisualizerCrossfade()
    private var data = VisualizerData()

    /// 32 RGBA texels per row, row 0 this track's and row 1 the last's.
    private(set) var paletteTexels = [UInt8](repeating: 0, count: VisualizerPalette.size * 2 * 4)
    /// 128 per row, the same two rows.
    private(set) var loudnessTexels = [Float](repeating: 0, count: VisualizerLoudness.texels * 2)
    private(set) var crossfadeValue: Float = 1
    /// Percent through the track, whole numbers, as Plexamp's engine reports it.
    private(set) var progress: Float = 0

    private init(buffer: AudioSampleBuffer) {
        self.buffer = buffer
    }

    func select(_ data: VisualizerData) {
        guard data != self.data else { return }
        self.data = data
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

    /// One frame: what `VisualizerHost::tick` does per animation frame.
    func tick() {
        if data.wantsSpectrum {
            if player?.isPlaying == true {
                buffer.snapshot(into: &samples)
                fft.magnitudes(of: samples, into: &magnitudes)
            } else {
                for index in magnitudes.indices { magnitudes[index] = 0 }
            }
            VisualizerSpectrum.bands(magnitudes: magnitudes, sampleRate: Int(buffer.sampleRate), into: &bands)
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

/// A cover's 32 visualiser colours, from the 150-pixel image Plexamp runs ColorCube over.
@MainActor
enum VisualizerArtworkPalette {
    private static var cache: [String: [VisualizerPalette.RGB]] = [:]

    static func colours(for coverArt: String?, artwork: ArtworkStore) async -> [VisualizerPalette.RGB]? {
        guard let coverArt else { return nil }
        if let cached = cache[coverArt] { return cached }
        guard let texture = await artwork.image(for: coverArt, size: .thumb) else { return nil }
        let colours = await Task.detached(priority: .utility) { () -> [VisualizerPalette.RGB] in
            let (pixels, width, height) = rgba(texture)
            return VisualizerPalette.gradient(fromQuadrantColours: ColorCube.quadrantColours(pixels: pixels, width: width, height: height))
        }.value
        guard colours.count == VisualizerPalette.size else { return nil }
        if cache.count > 256 { cache.removeAll() }
        cache[coverArt] = colours
        return colours
    }

    private static var cornerCache: [String: [VisualizerPalette.RGB]] = [:]

    /// The cover's four corner colours, clockwise from the top left, as Plexamp picks them
    /// for the player's background (`pickBestCircularGradientColors`).
    static func corners(for coverArt: String?, artwork: ArtworkStore) async -> [VisualizerPalette.RGB]? {
        guard let coverArt else { return nil }
        if let cached = cornerCache[coverArt] { return cached }
        guard let texture = await artwork.image(for: coverArt, size: .thumb) else { return nil }
        let colours = await Task.detached(priority: .utility) { () -> [VisualizerPalette.RGB] in
            let (pixels, width, height) = rgba(texture)
            return VisualizerPalette.pickCircularGradientColours(ColorCube.quadrantColours(pixels: pixels, width: width, height: height))
        }.value
        guard colours.count == 4 else { return nil }
        if cornerCache.count > 256 { cornerCache.removeAll() }
        cornerCache[coverArt] = colours
        return colours
    }

    /// RGBA rows from the texture's premultiplied BGRA, nearest-sampled to 150 across.
    nonisolated private static func rgba(_ texture: Texture) -> ([UInt8], Int, Int) {
        let (source, stride) = texture.pixels()
        let sourceWidth = texture.width
        let sourceHeight = texture.height
        guard sourceWidth > 0, sourceHeight > 0 else { return ([], 0, 0) }
        let aspect = Double(sourceWidth) / Double(sourceHeight)
        let width = aspect >= 1 ? 150 : max(1, Int(150 * aspect))
        let height = aspect >= 1 ? max(1, Int(150 / aspect)) : 150
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            let sy = min(sourceHeight - 1, y * sourceHeight / height)
            for x in 0..<width {
                let sx = min(sourceWidth - 1, x * sourceWidth / width)
                let from = sy * stride + sx * 4
                let to = (y * width + x) * 4
                pixels[to] = source[from + 2]
                pixels[to + 1] = source[from + 1]
                pixels[to + 2] = source[from]
                pixels[to + 3] = 255
            }
        }
        return (pixels, width, height)
    }
}
