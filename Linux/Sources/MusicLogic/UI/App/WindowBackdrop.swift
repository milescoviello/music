import CGtk
import Foundation

/// The cover's colours behind the whole window, not only the player: three of the cover's
/// own colours, each a wide pool of light, drifting slowly over a dark ground, with the
/// window's glass and pages over them.
///
/// Three, as far apart as the cover has them: one colour is a flat tint, and a whole
/// palette is noise. Each is held to a middle lightness and a little under its full
/// saturation, so white type reads over any of them and a pale sleeve doesn't make a pale
/// window.
///
/// The pools drift on slow, unequal orbits, so the blend never quite repeats; nothing else
/// in the window moves. A step a second, each too small to see: every step repaints the
/// whole window, which eight a second made the app slow. Drawn small and stretched to
/// fill, as the player's backdrop is: it is all gradient.
///
/// It drifts only while the window is the one in use, and not at all on a machine of two
/// cores or fewer (the 2009 MacBook): there the steps were most of what the app did while
/// it sat idle. Still, it is the same blend, only not moving.
@MainActor
final class WindowBackdrop {
    let root: Overlay
    private let picture = Picture().fit(GTK_CONTENT_FIT_FILL)
    private let app: AppState
    private var pools: [VisualizerPalette.RGB] = WindowBackdrop.resting
    private var aspect = 1.6
    private var time = Double.random(in: 0..<1_000)
    private var drift: Task<Void, Never>?
    private var cover: String?
    private var generation = 0
    private var isMapped = false
    private var setsAccent = true
    /// Whether the window is the one in use (`Shell`).
    var isActive = true {
        didSet { if isActive != oldValue { update() } }
    }
    private static let drifts = ProcessInfo.processInfo.activeProcessorCount > 2

    /// Before there is a cover: the app's accent, a deep blue and a violet, quietly.
    private static let resting = [
        VisualizerPalette.RGB(150, 40, 60), VisualizerPalette.RGB(30, 50, 110), VisualizerPalette.RGB(70, 40, 110),
    ]

    init(app: AppState) {
        self.app = app
        let sizer = DrawingArea { _, _, _ in }
        sizer.hexpand().vexpand().canTarget(false)
        root = Overlay(picture)
        root.add(sizer)
        root.css("window-backdrop")
        root.keep(self)

        let reference = WeakReference(self)
        sizer.onResize { width, height in
            guard let backdrop = reference.value, width > 0, height > 0 else { return }
            backdrop.aspect = Double(width) / Double(height)
            backdrop.draw()
        }
        root.onMap {
            reference.value?.isMapped = true
            reference.value?.update()
        }
        root.onUnmap {
            reference.value?.isMapped = false
            reference.value?.update()
        }
        draw()
    }

    /// Whose colours: a cover's art id, or nil for the resting ones. `accent`: whether the
    /// accent follows them too, which only the song playing's do: changing it restyles
    /// the whole window, every page the history keeps, which opening each album paid.
    func show(cover: String?, accent: Bool) {
        setsAccent = accent
        guard cover != self.cover else { return }
        self.cover = cover
        generation += 1
        let current = generation
        guard let cover else {
            pools = Self.resting
            if setsAccent { Style.setAccent(nil) }
            draw()
            return
        }
        Task { @MainActor in
            guard let colours = await VisualizerArtworkPalette.colours(for: cover, artwork: app.artwork),
                  current == self.generation
            else { return }
            self.pools = Self.pick(colours)
            if self.setsAccent { Style.setAccent(self.pools.max { Style.hsl($0).s < Style.hsl($1).s }) }
            self.draw()
        }
    }

    private func update() {
        if Self.drifts, isMapped, isActive { start() } else { stop() }
    }

    private func start() {
        guard drift == nil else { return }
        drift = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                time += 1
                draw()
            }
        }
    }

    private func stop() {
        drift?.cancel()
        drift = nil
    }

    private func draw() {
        picture.set(Self.render(pools, aspect: aspect, time: time))
    }

    /// Three colours from the cover's 32, each as unlike the ones before as the cover has.
    static func pick(_ colours: [VisualizerPalette.RGB]) -> [VisualizerPalette.RGB] {
        let usable = colours.map(tame).filter { colour in
            let high = max(colour.r, colour.g, colour.b)
            return high > 25
        }
        guard var chosen = usable.first.map({ [$0] }) else { return resting }
        func distance(_ a: VisualizerPalette.RGB, _ b: VisualizerPalette.RGB) -> Double {
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
                chosen.append(VisualizerPalette.RGB(base.r * 0.55, base.g * 0.55, base.b * 0.7))
            } else {
                chosen.append(next)
            }
        }
        return chosen
    }

    /// A middle lightness and a little less than full saturation.
    private static func tame(_ colour: VisualizerPalette.RGB) -> VisualizerPalette.RGB {
        let (r, g, b) = (colour.r / 255, colour.g / 255, colour.b / 255)
        let high = max(r, g, b)
        let low = min(r, g, b)
        let lightness = (high + low) / 2
        let target = min(max(lightness, 0.3), 0.46)
        let grey = (r + g + b) / 3
        // Towards grey by a fifth, then to the target lightness.
        let (sr, sg, sb) = (grey + (r - grey) * 0.8, grey + (g - grey) * 0.8, grey + (b - grey) * 0.8)
        let scale = lightness > 0.001 ? target / lightness : 1
        return VisualizerPalette.RGB(
            min(255, sr * scale * 255), min(255, sg * scale * 255), min(255, sb * scale * 255)
        )
    }

    /// The ground, the three pools over it, and a falloff that keeps the edges dark.
    nonisolated private static func render(_ pools: [VisualizerPalette.RGB], aspect: Double, time: Double) -> Texture {
        let width = 96
        let height = max(1, Int((Double(width) / aspect).rounded()))
        let w = aspect
        let h = 1.0
        // Each pool's orbit: its own speeds and phase, a centre near a third of the window.
        let orbits: [(cx: Double, cy: Double, sx: Double, sy: Double, ax: Double, ay: Double, phase: Double)] = [
            (0.25, 0.3, 0.011, 0.017, 0.22, 0.2, 0.0),
            (0.75, 0.35, 0.013, 0.009, 0.2, 0.24, 2.1),
            (0.5, 0.8, 0.008, 0.012, 0.28, 0.16, 4.2),
        ]
        let centres = orbits.map { orbit in
            ((orbit.cx + orbit.ax * sin(time * orbit.sx + orbit.phase)) * w,
             (orbit.cy + orbit.ay * cos(time * orbit.sy + orbit.phase * 1.3)) * h)
        }
        let radius = 0.85 * (w * w + h * h).squareRoot() / 1.6
        let ground = (r: 10.0, g: 10.0, b: 14.0)
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            let py = (Double(y) + 0.5) / Double(height) * h
            for x in 0..<width {
                let px = (Double(x) + 0.5) / Double(width) * w
                var (r, g, b) = ground
                for (index, colour) in pools.prefix(3).enumerated() {
                    let (cx, cy) = centres[index]
                    let distance = ((px - cx) * (px - cx) + (py - cy) * (py - cy)).squareRoot() / radius
                    guard distance < 1 else { continue }
                    // Smooth to nothing at the edge: no rim where a pool ends.
                    let falloff = 1 - distance
                    let alpha = 0.62 * falloff * falloff * (3 - 2 * falloff)
                    r = colour.r * alpha + r * (1 - alpha)
                    g = colour.g * alpha + g * (1 - alpha)
                    b = colour.b * alpha + b * (1 - alpha)
                }
                let index = (y * width + x) * 4
                pixels[index] = UInt8(clamping: Int(b.rounded()))
                pixels[index + 1] = UInt8(clamping: Int(g.rounded()))
                pixels[index + 2] = UInt8(clamping: Int(r.rounded()))
            }
        }
        return Texture(pixels: pixels, width: width, height: height)
    }
}
