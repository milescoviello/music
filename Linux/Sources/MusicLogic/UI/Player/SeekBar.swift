import CGtk
import Foundation

/// Plexamp's seekbar: the track's loudness from start to end, tinted up to where it has
/// played — Smooth as a filled curve, Bars as a bar per point — or a plain line. Click to
/// go somewhere, or drag to scrub; the seek happens on release.
///
/// Until the track's shape is known it is a flat line that works the same. Its own view,
/// as on the phone, because it reads `elapsed`, which ticks four times a second.
@MainActor
final class SeekBar {
    let root: Box
    private let app: AppState
    private let canvas: DrawingArea
    private let elapsedLabel = Label("0:00", "time")
    private let remainingLabel = Label("--:--", "time").xalign(1)
    private var scrub: Double?
    private var heights: [Float] = []
    private var trackID: String?

    private static let points = 128
    private static let barHeight = Double(SeekbarShape.maximumHeight)
    private static let slop = 8.0

    init(app: AppState) {
        self.app = app
        let reference = WeakReference<SeekBar>.placeholder
        canvas = DrawingArea(height: Int32(Self.barHeight + 2 * Self.slop)) { cairo, width, height in
            reference.value?.draw(cairo, width: width, height: height)
        }
        canvas.hexpand()
        root = Box.vertical(spacing: 2) {}
        root.append(canvas)
        root.append(Box.horizontal {
            elapsedLabel.hexpand()
            remainingLabel
        })
        reference.value = self
        root.keep(self)

        let player = app.player
        root.observe {
            guard let seekbar = reference.value else { return }
            _ = player.elapsed
            _ = player.duration
            seekbar.refreshTimes()
            seekbar.canvas.redraw()
        }
        root.observe {
            guard let seekbar = reference.value else { return }
            let id = player.currentSong?.id
            let style = app.playerSettings.seekbarStyle
            if id != seekbar.trackID { seekbar.scrub = nil }
            seekbar.trackID = id
            if let id, let levels = app.seekbarLevels.levels(for: id) {
                seekbar.heights = SeekbarShape.interpolate(SeekbarShape.heights(fromLevels: levels), to: Self.points)
            } else {
                seekbar.heights = []
            }
            if let id, style != .line {
                Task { @MainActor in
                    _ = app.shapes.shape(for: id)
                    app.seekbarLevels.request([id])
                }
            }
            seekbar.canvas.redraw()
        }

        let drag = gtk_gesture_drag_new()!
        var start = 0.0
        Signal.connect(drag, "drag-begin", point: { x, _ in
            start = x
            reference.value?.scrubbed(to: x)
        })
        Signal.connect(drag, "drag-update", point: { dx, _ in
            reference.value?.scrubbed(to: start + dx)
        })
        Signal.connect(drag, "drag-end", point: { dx, _ in
            reference.value?.commit(at: start + dx)
        })
        gtk_widget_add_controller(canvas.widget, drag.cast())
        gtk_widget_set_cursor_from_name(canvas.widget, "pointer")
    }

    private var duration: Double { app.player.duration }
    private var position: Double { scrub ?? app.player.elapsed }

    private func fraction(_ x: Double) -> Double {
        let width = Double(canvas.width)
        guard width > 0 else { return 0 }
        return min(max(x / width, 0), 1)
    }

    private func scrubbed(to x: Double) {
        guard duration > 0 else { return }
        scrub = fraction(x) * duration
        refreshTimes()
        canvas.redraw()
    }

    private func commit(at x: Double) {
        guard duration > 0 else {
            scrub = nil
            return
        }
        app.player.seek(to: fraction(x) * duration)
        scrub = nil
        canvas.redraw()
    }

    private func refreshTimes() {
        elapsedLabel.text = Int(position).asDuration
        // Rather than "0:00", which reads as a bug — and was one.
        remainingLabel.text = duration > 0 ? "-" + Int(max(duration - position, 0)).asDuration : "--:--"
        canvas.opacity(duration > 0 ? 1 : 0.35)
    }

    private func draw(_ cairo: Cairo, width: Double, height: Double) {
        let progress = duration > 0 ? min(1, max(0, position / duration)) : 0
        let top = Self.slop
        let barHeight = Self.barHeight
        let style = app.playerSettings.seekbarStyle

        func shape() {
            switch style {
            case .line:
                cairo.roundedRectangle(0, top + barHeight / 2 - 2, width, 4, radius: 2)
            case .bars:
                let count = max(1, min(heights.isEmpty ? Self.points : heights.count, Int(width / 2.5)))
                let values = resampled(count)
                let slot = width / Double(count)
                let barWidth = max(1, slot * 0.65)
                for (index, value) in values.enumerated() {
                    let h = min(value, barHeight)
                    cairo.roundedRectangle(Double(index) * slot + (slot - barWidth) / 2, top + barHeight - h, barWidth, h, radius: barWidth / 2)
                }
            case .smooth:
                // A filled curve through the midpoints, each a quadratic with the point
                // itself as control — the phone's path, as cairo's cubics.
                let values = resampled(max(2, heights.count))
                let step = width / Double(values.count - 1)
                let points = values.enumerated().map { (Double($0.offset) * step, top + barHeight - min($0.element, barHeight)) }
                cairo.move(0, top + barHeight)
                cairo.line(points[0].0, points[0].1)
                var current = points[0]
                for index in 1..<points.count {
                    let control = points[index - 1]
                    let end = ((control.0 + points[index].0) / 2, (control.1 + points[index].1) / 2)
                    cairo.curve(
                        current.0 + (control.0 - current.0) * 2 / 3, current.1 + (control.1 - current.1) * 2 / 3,
                        end.0 + (control.0 - end.0) * 2 / 3, end.1 + (control.1 - end.1) * 2 / 3,
                        end.0, end.1
                    )
                    current = end
                }
                cairo.line(points[points.count - 1].0, points[points.count - 1].1)
                cairo.line(width, top + barHeight)
                cairo.close()
            }
        }

        cairo.color(red: 1, green: 1, blue: 1, alpha: 0.25)
        shape()
        cairo.fill()

        cairo.save()
        cairo.rectangle(0, 0, width * progress, height)
        cairo.clip()
        cairo.color(Style.tint)
        shape()
        cairo.fill()
        cairo.restore()

        // The playhead.
        let thickness = scrub == nil ? 2.0 : 3.0
        cairo.color(red: 1, green: 1, blue: 1)
        cairo.roundedRectangle(min(max(width * progress - thickness / 2, 0), width - thickness), top - 2, thickness, barHeight + 4, radius: thickness / 2)
        cairo.fill()
    }

    /// The heights across `count` points, flat while the shape is not known.
    private func resampled(_ count: Int) -> [Double] {
        let source = heights.isEmpty ? [Float(0)] : heights
        let values = source.count == count ? source : SeekbarShape.interpolate(source, to: count)
        return values.map { max(2, Double($0)) }
    }
}

extension WeakReference {
    /// One made before its object exists, for closures built during `init`.
    static var placeholder: WeakReference<Object> {
        WeakReference<Object>(nil)
    }
}
