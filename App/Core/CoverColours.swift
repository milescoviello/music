import Foundation

/// The colours a cover lends the pages behind it, the same on the phone and on Linux:
/// three of the cover's own colours, each a wide pool of light over a dark ground, and the
/// accent the playing song lends the whole app.
///
/// Three, as far apart as the cover has them: one colour is a flat tint, and a whole
/// palette is noise. Each is held to a middle lightness and a little under its full
/// saturation, so white type reads over any of them and a pale sleeve doesn't make a pale
/// page.
enum CoverColours {
    typealias RGB = VisualizerPalette.RGB

    /// Before there is a cover: the app's accent, a deep blue and a violet, quietly.
    static let resting = [RGB(150, 40, 60), RGB(30, 50, 110), RGB(70, 40, 110)]

    /// What the pools lie on.
    static let ground = RGB(10, 10, 14)

    /// How strongly a pool shows at its centre; it falls smoothly to nothing at its edge.
    static let poolStrength = 0.62

    /// Each pool's slow orbit: a centre (as fractions of the page), its speeds, its reach
    /// and its phase. Unequal, so the blend never quite repeats.
    static let orbits: [(cx: Double, cy: Double, sx: Double, sy: Double, ax: Double, ay: Double, phase: Double)] = [
        (0.25, 0.3, 0.011, 0.017, 0.22, 0.2, 0.0),
        (0.75, 0.35, 0.013, 0.009, 0.2, 0.24, 2.1),
        (0.5, 0.8, 0.008, 0.012, 0.28, 0.16, 4.2),
    ]

    /// Where pool `index` is at `time` seconds, as fractions of the page's width and height.
    static func centre(_ index: Int, time: Double) -> (x: Double, y: Double) {
        let orbit = orbits[index % orbits.count]
        return (orbit.cx + orbit.ax * sin(time * orbit.sx + orbit.phase),
                orbit.cy + orbit.ay * cos(time * orbit.sy + orbit.phase * 1.3))
    }

    /// A pool's radius on a page `width` by `height`, in the same units.
    static func radius(width: Double, height: Double) -> Double {
        0.85 * (width * width + height * height).squareRoot() / 1.6
    }

    /// Three colours from the cover's 32 (`VisualizerPalette`), each as unlike the ones
    /// before as the cover has.
    static func pick(_ colours: [RGB]) -> [RGB] {
        let usable = colours.map(tame).filter { max($0.r, $0.g, $0.b) > 25 }
        guard var chosen = usable.first.map({ [$0] }) else { return resting }
        func distance(_ a: RGB, _ b: RGB) -> Double {
            let (dr, dg, db) = (a.r - b.r, a.g - b.g, a.b - b.b)
            return dr * dr * 0.3 + dg * dg * 0.59 + db * db * 0.11
        }
        while chosen.count < 3 {
            guard let next = usable.max(by: { a, b in
                chosen.map { distance($0, a) }.min()! < chosen.map { distance($0, b) }.min()!
            }) else { break }
            // A cover of one colour: its shades, rather than a colour it doesn't have.
            if chosen.map({ distance($0, next) }).min()! < 120 {
                let base = chosen[0]
                chosen.append(RGB(base.r * 0.55, base.g * 0.55, base.b * 0.7))
            } else {
                chosen.append(next)
            }
        }
        return chosen
    }

    /// A middle lightness and a little less than full saturation.
    static func tame(_ colour: RGB) -> RGB {
        let (r, g, b) = (colour.r / 255, colour.g / 255, colour.b / 255)
        let high = max(r, g, b)
        let low = min(r, g, b)
        let lightness = (high + low) / 2
        let target = min(max(lightness, 0.3), 0.46)
        let grey = (r + g + b) / 3
        // Towards grey by a fifth, then to the target lightness.
        let (sr, sg, sb) = (grey + (r - grey) * 0.8, grey + (g - grey) * 0.8, grey + (b - grey) * 0.8)
        let scale = lightness > 0.001 ? target / lightness : 1
        return RGB(min(255, sr * scale * 255), min(255, sg * scale * 255), min(255, sb * scale * 255))
    }

    /// The accent a song's pools lend the app: the most saturated of them, at `lightness`,
    /// its saturation held between 0.45 and 0.85 so it is neither grey nor garish. 0...1
    /// per channel.
    static func accent(from pools: [RGB], lightness: Double) -> (r: Double, g: Double, b: Double)? {
        guard let colour = pools.max(by: { hsl($0).s < hsl($1).s }) else { return nil }
        let (h, s, _) = hsl(colour)
        return rgb(h, min(max(s, 0.45), 0.85), lightness)
    }

    /// Hue, saturation and lightness, each 0...1.
    static func hsl(_ c: RGB) -> (h: Double, s: Double, l: Double) {
        let (r, g, b) = (c.r / 255, c.g / 255, c.b / 255)
        let high = max(r, g, b)
        let low = min(r, g, b)
        let l = (high + low) / 2
        guard high != low else { return (0, 0, l) }
        let d = high - low
        let s = l > 0.5 ? d / (2 - high - low) : d / (high + low)
        let h: Double
        switch high {
        case r: h = (g - b) / d + (g < b ? 6 : 0)
        case g: h = (b - r) / d + 2
        default: h = (r - g) / d + 4
        }
        return (h / 6, s, l)
    }

    /// Back from hue, saturation and lightness: 0...1 per channel.
    static func rgb(_ h: Double, _ s: Double, _ l: Double) -> (r: Double, g: Double, b: Double) {
        guard s > 0 else { return (l, l, l) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        func channel(_ t: Double) -> Double {
            var t = t
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 0.5 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        return (channel(h + 1.0 / 3), channel(h), channel(h - 1.0 / 3))
    }
}
