import CGtk
import Foundation

/// The player's visualiser mode. Plexamp's spectrum, drawn with cairo from the shared
/// feed: 64 bands in the cover's colours, with falling peaks — what Plexamp's Spectrum
/// program draws.
@MainActor
final class VisualizerPane {
    /// Plexamp's Higher Quality Visualizers, the phone's key.
    static let highQualityKey = "visualizer.highQuality"

    let root: Widget
    private let feed: VisualizerFeed
    private let canvas: DrawingArea
    private var tickID: guint = 0
    private var colours: [VisualizerPalette.RGB] = []

    init(app: AppState) {
        feed = VisualizerFeed.shared(buffer: app.spectrumBuffer)
        feed.player = app.player
        feed.select(VisualizerData(frequency: true, peaks: true, alpha: 0.3))
        let reference = WeakReference<VisualizerPane>(nil)
        canvas = DrawingArea { cairo, width, height in
            reference.value?.draw(cairo, width: width, height: height)
        }
        canvas.hexpand().vexpand()
        root = canvas
        reference.value = self
        root.keep(self)

        // Animated only while on screen: an FFT nobody is looking at is pure battery.
        canvas.onMap {
            guard let pane = reference.value, pane.tickID == 0 else { return }
            app.player.startSpectrum()
            pane.tickID = tick(pane.canvas) {
                guard let pane = reference.value else { return false }
                pane.feed.tick()
                pane.canvas.redraw()
                return true
            }
        }
        canvas.onUnmap {
            guard let pane = reference.value, pane.tickID != 0 else { return }
            gtk_widget_remove_tick_callback(pane.canvas.widget, pane.tickID)
            pane.tickID = 0
        }
        root.observe {
            let cover = app.player.currentSong?.coverArt
            Task { @MainActor in
                guard let colours = await VisualizerArtworkPalette.colours(for: cover, artwork: app.artwork) else { return }
                reference.value?.colours = colours
                reference.value?.feed.setPalette(colours)
            }
        }
    }

    private func draw(_ cairo: Cairo, width: Double, height: Double) {
        let texels = feed.host.frequencyTexels
        let count = VisualizerSpectrum.bandCount
        guard texels.count >= count * 2, width > 0, height > 0 else { return }
        let slot = width / Double(count)
        let barWidth = max(1, slot * 0.7)
        // The band values top out a little under 0.48.
        let scale = height / 0.48
        for band in 0..<count {
            let colour = colours.isEmpty
                ? VisualizerPalette.RGB(Style.tint.red * 255, Style.tint.green * 255, Style.tint.blue * 255)
                : colours[band * colours.count / count]
            let rgb = ArtworkStore.RGB(red: colour.r / 255, green: colour.g / 255, blue: colour.b / 255)
            let level = min(height, Double(texels[band]) * scale)
            let x = Double(band) * slot + (slot - barWidth) / 2
            cairo.color(rgb, alpha: 0.9)
            cairo.roundedRectangle(x, height - level, barWidth, max(level, 2), radius: barWidth / 3)
            cairo.fill()
            let peak = min(height, Double(texels[count + band]) * scale)
            cairo.color(rgb, alpha: 1)
            cairo.rectangle(x, height - peak - 3, barWidth, 2)
            cairo.fill()
        }
    }
}
