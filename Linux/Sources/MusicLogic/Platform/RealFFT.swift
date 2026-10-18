import Foundation

/// The visualiser's FFT without Accelerate: a radix-2 real transform of a Hann-windowed
/// block, giving `size / 2` magnitudes, as `vDSP_fft_zrip` and `vDSP_zvabs` do on the
/// phone — so `SpectrumAnalyser` maps bands and decibels identically on both.
///
/// The real signal is packed into a complex one of half the length and untangled after,
/// the standard trick, so a 2048-point block costs a 1024-point complex transform. Thirty
/// times a second on the main actor, that is nothing.
final class RealFFT: @unchecked Sendable {
    let size: Int
    private let half: Int
    private let window: [Float]
    private var real: [Float]
    private var imaginary: [Float]
    private let cosines: [Float]
    private let sines: [Float]
    private let reversed: [Int]

    init(size: Int) {
        self.size = size
        half = size / 2
        window = (0..<size).map { index in
            0.5 * (1 - cos(2 * .pi * Float(index) / Float(size)))
        }
        real = [Float](repeating: 0, count: size / 2)
        imaginary = [Float](repeating: 0, count: size / 2)
        cosines = (0..<size / 2).map { cos(2 * .pi * Float($0) / Float(size)) }
        sines = (0..<size / 2).map { -sin(2 * .pi * Float($0) / Float(size)) }

        let bits = Int(log2(Double(size / 2)).rounded())
        reversed = (0..<size / 2).map { index in
            var value = 0
            for bit in 0..<bits where index & (1 << bit) != 0 {
                value |= 1 << (bits - 1 - bit)
            }
            return value
        }
    }

    /// Writes `size / 2` magnitudes for `samples`. False if the sizes do not match.
    func magnitudes(of samples: [Float], into output: inout [Float]) -> Bool {
        guard samples.count == size, output.count == half else { return false }

        // Even samples as the real part, odd as the imaginary, in bit-reversed order.
        for index in 0..<half {
            let target = reversed[index]
            real[target] = samples[2 * index] * window[2 * index]
            imaginary[target] = samples[2 * index + 1] * window[2 * index + 1]
        }

        // Iterative Cooley-Tukey over the half-length complex signal.
        var length = 2
        while length <= half {
            let stride = size / length
            for start in Swift.stride(from: 0, to: half, by: length) {
                for offset in 0..<length / 2 {
                    let twiddle = offset * stride
                    let wr = cosines[twiddle]
                    let wi = sines[twiddle]
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

        // Untangle the packed transform into the real signal's first half-spectrum.
        for bin in 0..<half {
            let mirror = bin == 0 ? 0 : half - bin
            let evenReal = (real[bin] + real[mirror]) / 2
            let evenImaginary = (imaginary[bin] - imaginary[mirror]) / 2
            let oddReal = (imaginary[bin] + imaginary[mirror]) / 2
            let oddImaginary = -(real[bin] - real[mirror]) / 2
            let wr = cosines[bin]
            let wi = sines[bin]
            let spectrumReal = evenReal + oddReal * wr - oddImaginary * wi
            let spectrumImaginary = evenImaginary + oddReal * wi + oddImaginary * wr
            // vDSP's packed real FFT is scaled by two; matched so the decibels line up.
            output[bin] = 2 * (spectrumReal * spectrumReal + spectrumImaginary * spectrumImaginary).squareRoot()
        }
        return true
    }
}
