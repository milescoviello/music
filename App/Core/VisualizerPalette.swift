import Foundation

/// The 32 colours every visualiser draws with, from the album art, the way Plexamp
/// derives them. Three steps, each a port:
///
/// 1. **ColorCube** over the cover at 150 px (`ColorCube::extractQuadrantColorsFromImage`
///    in Plexamp's native engine): five colours from each corner, clockwise from the top
///    left, so twenty in all.
/// 2. **Pick four** of those (`pickBestCircularGradientColors` in Plexamp's JS): one per
///    corner, preferring colourful over grey and different hues over similar ones, then
///    every one set to 30–33 % lightness. That darkening is why Plexamp's visualisers
///    glow rather than glare.
/// 3. **Stretch to 32** (`ColorCube::InterpolateRgb`): the four, reversed, interpolated
///    linearly per channel.
enum VisualizerPalette {
    static let size = 32

    /// 0...255 per channel. Doubles, because the JS colour library Plexamp uses keeps
    /// unrounded values between its conversions and only rounds when writing hex.
    struct RGB: Sendable, Equatable {
        var r: Double
        var g: Double
        var b: Double

        init(_ r: Double, _ g: Double, _ b: Double) {
            self.r = r
            self.g = g
            self.b = b
        }

        init(hex: Int) {
            self.init(Double((hex >> 16) & 0xFF), Double((hex >> 8) & 0xFF), Double(hex & 0xFF))
        }

        /// What `color.hex()` gives back, parsed again: each channel rounded.
        var rounded: RGB { RGB(r.rounded(), g.rounded(), b.rounded()) }
    }

    /// Steps 2 and 3, from ColorCube's twenty colours to the texture's thirty-two.
    static func gradient(fromQuadrantColours colours: [RGB]) -> [RGB] {
        interpolate(Array(pickCircularGradientColours(colours).reversed()), count: size)
    }

    // MARK: - Picking four

    /// `pickBestCircularGradientColors`: one colour per group of five, each chosen
    /// against the one before so neighbouring corners differ in hue.
    static func pickCircularGradientColours(_ palette: [RGB]) -> [RGB] {
        var palette = palette
        if palette.count < 20 {
            palette += Array(repeating: RGB(0xDD, 0xDD, 0xDD), count: 20 - palette.count)
        }
        let candidates = palette.prefix(20).map(Candidate.init)

        let first = boringFiltered(Array(candidates[0..<5]), after: nil)
        let second = boringFiltered(Array(candidates[5..<10]), after: first)
        let third = boringFiltered(Array(candidates[10..<15]), after: second)
        let fourth = boringFiltered(Array(candidates[15..<20]), after: third)

        var picked = [first, second, third, fourth].map { candidate -> HSL in
            let hsl = HSL(candidate.colour)
            return hsl.withLightness(hsl.s > 80 ? 30 : 33)
        }

        if percentageDifferent(picked[0].rgb, picked[1].rgb) < 15 {
            stretchLightness(&picked, 0, 1, by: 10)
        }
        if percentageDifferent(picked[2].rgb, picked[3].rgb) < 15 {
            stretchLightness(&picked, 2, 3, by: 10)
        }

        return picked.map { $0.rgb.rounded }
    }

    /// A colour with the two measures the picker filters on. Both are HSV-style:
    /// "lum" is the brightest channel and "sat" its spread, in percent.
    private struct Candidate {
        let colour: RGB
        let lum: Double
        let sat: Double
        let hue: Double

        init(_ colour: RGB) {
            self.colour = colour
            let high = max(colour.r, colour.g, colour.b) / 255
            let low = min(colour.r, colour.g, colour.b) / 255
            lum = high * 100
            sat = high > 0 ? (high - low) / high * 100 : 0
            hue = HSL(colour).h
        }

        func within(sat: ClosedRange<Double>, lum: ClosedRange<Double>) -> Bool {
            sat.contains(self.sat) && lum.contains(self.lum)
        }
    }

    /// `dropBoringColorsInStages`: the first of these that finds anything wins.
    private static func boringFiltered(_ group: [Candidate], after previous: Candidate?) -> Candidate {
        func keep(_ from: [Candidate], sat: ClosedRange<Double>, lum: ClosedRange<Double>) -> [Candidate]? {
            let kept = from.filter { $0.within(sat: sat, lum: lum) }
            return kept.isEmpty ? nil : kept
        }

        let rest = Array(group.dropFirst())
        let stages: [() -> [Candidate]?] = [
            { mostDifferent(keep(group, sat: 15...100, lum: 20...99), from: previous) },
            { mostDifferent(keep(Array(group.prefix(2)), sat: 2...40, lum: 30...95), from: previous) },
            { keep([group[1]], sat: 2...40, lum: 60...95) },
            { mostDifferent(keep(rest, sat: 30...100, lum: 25...100), from: previous) },
            { mostDifferent(keep(rest, sat: 15...100, lum: 25...100), from: previous) },
            { mostDifferent(keep(group, sat: 5...90, lum: 5...90), from: previous) },
        ]
        for stage in stages {
            if let found = stage(), let first = found.first { return first }
        }
        return group[0]
    }

    /// `getMostDifferentColor`: the first candidate more than 20° of hue from the last
    /// pick, or failing that the furthest.
    private static func mostDifferent(_ candidates: [Candidate]?, from previous: Candidate?) -> [Candidate]? {
        guard let candidates, candidates.count >= 2, let previous else { return candidates }
        var best: Candidate?
        var bestDistance = -1.0
        for candidate in candidates {
            let raw = abs(previous.hue - candidate.hue)
            let distance = min(raw, 360 - raw)
            if distance > bestDistance {
                bestDistance = distance
                best = candidate
            }
            if distance > 20 { return [candidate] }
        }
        return best.map { [$0] }
    }

    /// Mean channel difference, in percent.
    static func percentageDifferent(_ a: RGB, _ b: RGB) -> Double {
        (abs(a.r - b.r) / 255 + abs(a.g - b.g) / 255 + abs(a.b - b.b) / 255) / 3 * 100
    }

    /// `stretchColorPair` on lightness: push the lighter one up and the darker one down.
    private static func stretchLightness(_ colours: inout [HSL], _ first: Int, _ second: Int, by amount: Double) {
        if colours[first].l > colours[second].l {
            colours[first] = colours[first].withLightness(colours[first].l + amount)
            colours[second] = colours[second].withLightness(colours[second].l - amount)
        } else {
            colours[first] = colours[first].withLightness(colours[first].l - amount)
            colours[second] = colours[second].withLightness(colours[second].l + amount)
        }
    }

    /// HSL as the `color-convert` package computes it, unrounded, in degrees and percent.
    struct HSL: Sendable, Equatable {
        var h: Double
        var s: Double
        var l: Double

        init(h: Double, s: Double, l: Double) {
            self.h = h
            self.s = s
            self.l = l
        }

        init(_ colour: RGB) {
            let r = colour.r / 255
            let g = colour.g / 255
            let b = colour.b / 255
            let low = min(r, g, b)
            let high = max(r, g, b)
            let delta = high - low

            var hue: Double
            if high == low {
                hue = 0
            } else if r == high {
                hue = (g - b) / delta
            } else if g == high {
                hue = 2 + (b - r) / delta
            } else {
                hue = 4 + (r - g) / delta
            }
            hue = min(hue * 60, 360)
            if hue < 0 { hue += 360 }

            let lightness = (low + high) / 2
            let saturation: Double
            if high == low {
                saturation = 0
            } else if lightness <= 0.5 {
                saturation = delta / (high + low)
            } else {
                saturation = delta / (2 - high - low)
            }
            self.init(h: hue, s: saturation * 100, l: lightness * 100)
        }

        /// The colour library's setter, which clamps to 0...100.
        func withLightness(_ value: Double) -> HSL {
            HSL(h: h, s: s, l: min(max(value, 0), 100))
        }

        var rgb: RGB {
            let h = self.h / 360
            let s = self.s / 100
            let l = self.l / 100
            if s == 0 {
                return RGB(l * 255, l * 255, l * 255)
            }
            let t2 = l < 0.5 ? l * (1 + s) : l + s - l * s
            let t1 = 2 * l - t2
            var channels = [0.0, 0.0, 0.0]
            for index in 0..<3 {
                var t3 = h + 1 / 3 * -Double(index - 1)
                if t3 < 0 { t3 += 1 }
                if t3 > 1 { t3 -= 1 }
                let value: Double
                if 6 * t3 < 1 {
                    value = t1 + (t2 - t1) * 6 * t3
                } else if 2 * t3 < 1 {
                    value = t2
                } else if 3 * t3 < 2 {
                    value = t1 + (t2 - t1) * (2 / 3 - t3) * 6
                } else {
                    value = t1
                }
                channels[index] = value * 255
            }
            return RGB(channels[0], channels[1], channels[2])
        }
    }

    // MARK: - Stretching to 32

    /// `ColorCube::InterpolateRgb`: each channel through `Utils::Interpolate`, in Float
    /// as the original does, and truncated back to bytes. Thirty-two or more colours are
    /// taken as they are.
    static func interpolate(_ colours: [RGB], count: Int) -> [RGB] {
        guard !colours.isEmpty else { return [] }
        if colours.count >= count { return Array(colours.prefix(count)) }

        func channel(_ value: (RGB) -> Double) -> [Float] {
            VisualizerLoudness.interpolate(colours.map { Float(value($0)) / 255 }, count: count)
        }
        func byte(_ value: Float) -> Double {
            Double(Int(Double(value) * 255))
        }
        let reds = channel(\.r)
        let greens = channel(\.g)
        let blues = channel(\.b)
        var gradient: [RGB] = []
        gradient.reserveCapacity(count)
        for index in 0..<count {
            gradient.append(RGB(byte(reds[index]), byte(greens[index]), byte(blues[index])))
        }
        return gradient
    }
}

/// Ole Krause-Sparmann's ColorCube (MIT), as Plexamp's native engine runs it: a
/// 30×30×30 histogram of a region's colours, its local maxima in order of how many
/// pixels landed there, minus anything near black or white, thinned until distinct.
enum ColorCube {
    private static let resolution = 30

    /// Twenty colours: five per corner region, each region 40 % of the image on a side,
    /// clockwise from the top left. A region that yields fewer than five repeats its first;
    /// one that yields none (a black or white corner) is tried again unfiltered.
    ///
    /// `pixels` is 8-bit RGBA, rows top to bottom.
    static func quadrantColours(pixels: [UInt8], width: Int, height: Int, perRegion count: Int = 5) -> [VisualizerPalette.RGB] {
        guard width > 0, height > 0, pixels.count >= width * height * 4 else { return [] }

        let fraction: Float = 0.4
        let w = Float(width)
        let h = Float(height)
        let regions = [
            Region(x0: 0, y0: 0, x1: Int(w * fraction), y1: Int(h * fraction)),
            Region(x0: Int(w - fraction * w), y0: 0, x1: width, y1: Int(h * fraction)),
            Region(x0: Int(w - fraction * w), y0: Int(h - fraction * h), x1: width, y1: height),
            Region(x0: 0, y0: Int(h - fraction * h), x1: Int(w * fraction), y1: height),
        ]

        var colours: [VisualizerPalette.RGB] = []
        for region in regions {
            var found = regionColours(region, pixels: pixels, width: width, filtered: true, count: count)
            if found.isEmpty {
                found = regionColours(region, pixels: pixels, width: width, filtered: false, count: nil)
            }
            guard let first = found.first else { continue }
            for index in 0..<count {
                colours.append(index < found.count ? found[index] : first)
            }
        }
        return colours
    }

    private struct Region {
        let x0: Int
        let y0: Int
        let x1: Int
        let y1: Int
    }

    private struct Maximum {
        let hits: Int
        let r: Double
        let g: Double
        let b: Double

        func distance(to other: (Double, Double, Double)) -> Double {
            let dr = r - other.0
            let dg = g - other.1
            let db = b - other.2
            return (dr * dr + dg * dg + db * db).squareRoot()
        }
    }

    /// The colours as Plexamp hands them to JS: hex strings, each channel `Int(c × 255)`.
    private static func regionColours(
        _ region: Region,
        pixels: [UInt8],
        width: Int,
        filtered: Bool,
        count: Int?
    ) -> [VisualizerPalette.RGB] {
        var maxima = localMaxima(in: region, pixels: pixels, width: width)
        if filtered {
            maxima = maxima.filter { $0.distance(to: (0, 0, 0)) >= 0.25 }
            maxima = maxima.filter { $0.distance(to: (1, 1, 1)) >= 0.25 }
        }
        if let count {
            maxima = adaptivelyDistinct(maxima, count: count)
        }
        // Through Float first, as the original stores them: 200/255 as a Double times 255
        // truncates to 199, as a Float to 200.
        func byte(_ value: Double) -> Double { Double(Int(Double(Float(value)) * 255)) }
        return maxima.map { VisualizerPalette.RGB(byte($0.r), byte($0.g), byte($0.b)) }
    }

    private static func localMaxima(in region: Region, pixels: [UInt8], width: Int) -> [Maximum] {
        let size = resolution
        let cellCount = size * size * size
        var hits = [Int](repeating: 0, count: cellCount)
        var sums = [Double](repeating: 0, count: cellCount * 3)

        let scale = Double(size - 1)
        if region.y0 < region.y1, region.x0 < region.x1 {
            for y in region.y0..<region.y1 {
                for x in region.x0..<region.x1 {
                    let offset = (y * width + x) * 4
                    let r = Double(pixels[offset]) / 255
                    let g = Double(pixels[offset + 1]) / 255
                    let b = Double(pixels[offset + 2]) / 255
                    let cell = Int(r * scale) + Int(g * scale) * size + Int(b * scale) * size * size
                    hits[cell] += 1
                    sums[cell * 3] += r
                    sums[cell * 3 + 1] += g
                    sums[cell * 3 + 2] += b
                }
            }
        }

        var maxima: [Maximum] = []
        for r in 0..<size {
            for g in 0..<size {
                for b in 0..<size {
                    let cell = r + g * size + b * size * size
                    let local = hits[cell]
                    guard local > 0 else { continue }

                    var isMaximum = true
                    neighbours: for dr in -1...1 {
                        for dg in -1...1 {
                            for db in -1...1 {
                                let nr = r + dr
                                let ng = g + dg
                                let nb = b + db
                                guard nr >= 0, ng >= 0, nb >= 0, nr < size, ng < size, nb < size else { continue }
                                if hits[nr + ng * size + nb * size * size] > local {
                                    isMaximum = false
                                    break neighbours
                                }
                            }
                        }
                    }
                    guard isMaximum else { continue }

                    let total = Double(local)
                    maxima.append(Maximum(
                        hits: local,
                        r: sums[cell * 3] / total,
                        g: sums[cell * 3 + 1] / total,
                        b: sums[cell * 3 + 2] / total
                    ))
                }
            }
        }

        // Stable, so equal counts keep cube order; the original's unstable sort leaves
        // ties in no particular order, and this is one of the orders it could give.
        return maxima.enumerated()
            .sorted { $0.element.hits != $1.element.hits ? $0.element.hits > $1.element.hits : $0.offset < $1.offset }
            .map(\.element)
    }

    /// More than `count`? Thin with a rising distinctness threshold, keeping the last
    /// result that still had more than `count`, then take the first `count` of it.
    private static func adaptivelyDistinct(_ maxima: [Maximum], count: Int) -> [Maximum] {
        guard maxima.count > count else { return maxima }
        var current = maxima
        var threshold = Float(0.1)
        for _ in 0..<10 {
            let thinned = distinct(current, threshold: Double(threshold))
            if thinned.count <= count { break }
            current = thinned
            threshold = Float(Double(threshold) + 0.05)
        }
        return Array(current.prefix(count))
    }

    /// Keeps a maximum only if no maximum before it in the list — kept or not — is
    /// within `threshold`.
    private static func distinct(_ maxima: [Maximum], threshold: Double) -> [Maximum] {
        var kept: [Maximum] = []
        for (index, candidate) in maxima.enumerated() {
            let isDistinct = !maxima[..<index].contains {
                candidate.distance(to: ($0.r, $0.g, $0.b)) < threshold
            }
            if isDistinct { kept.append(candidate) }
        }
        return kept
    }
}
