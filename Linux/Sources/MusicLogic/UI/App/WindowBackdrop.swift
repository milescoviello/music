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
    private var pools: [VisualizerPalette.RGB] = CoverColours.resting
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
        // Playing or not decides whether it drifts.
        root.observe {
            _ = app.player.isPlaying
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
            pools = CoverColours.resting
            if setsAccent { Style.setAccent(nil) }
            draw()
            return
        }
        Task { @MainActor in
            guard let colours = await VisualizerArtworkPalette.colours(for: cover, artwork: app.artwork),
                  current == self.generation
            else { return }
            self.pools = CoverColours.pick(colours)
            if self.setsAccent { Style.setAccent(self.pools.max { Style.hsl($0).s < Style.hsl($1).s }) }
            self.draw()
        }
    }

    /// Drifting only while music plays, the window is the one in use, and the machine is
    /// on mains power: each step repaints the whole window, which on battery is not worth
    /// a blend nobody would miss standing still.
    private func update() {
        if Self.drifts, isMapped, isActive, app.player.isPlaying, !Self.onBattery() { start() } else { stop() }
    }

    private func start() {
        guard drift == nil else { return }
        drift = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                // Unplugged since: still, until the next change looks again.
                if Self.onBattery() {
                    stop()
                    return
                }
                time += 1
                draw()
            }
        }
    }

    /// Whether the machine runs on its battery: a mains supply that says it is offline. A
    /// desktop has no mains entry in sysfs, and so is never on battery.
    private static func onBattery() -> Bool {
        let root = URL(fileURLWithPath: "/sys/class/power_supply")
        guard let supplies = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return false }
        for supply in supplies {
            let folder = root.appendingPathComponent(supply)
            guard let type = try? String(contentsOf: folder.appendingPathComponent("type"), encoding: .utf8),
                  type.trimmingCharacters(in: .whitespacesAndNewlines) == "Mains",
                  let online = try? String(contentsOf: folder.appendingPathComponent("online"), encoding: .utf8)
            else { continue }
            return online.trimmingCharacters(in: .whitespacesAndNewlines) == "0"
        }
        return false
    }

    private func stop() {
        drift?.cancel()
        drift = nil
    }

    private func draw() {
        picture.set(Self.render(pools, aspect: aspect, time: time))
    }

    /// The ground, the three pools over it, and a falloff that keeps the edges dark.
    nonisolated private static func render(_ pools: [VisualizerPalette.RGB], aspect: Double, time: Double) -> Texture {
        let width = 96
        let height = max(1, Int((Double(width) / aspect).rounded()))
        let w = aspect
        let h = 1.0
        let centres = (0..<3).map { index in
            let centre = CoverColours.centre(index, time: time)
            return (centre.x * w, centre.y * h)
        }
        let radius = CoverColours.radius(width: w, height: h)
        let ground = (r: CoverColours.ground.r, g: CoverColours.ground.g, b: CoverColours.ground.b)
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
                    let alpha = CoverColours.poolStrength * falloff * falloff * (3 - 2 * falloff)
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
