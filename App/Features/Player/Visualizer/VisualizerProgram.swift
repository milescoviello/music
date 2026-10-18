import Foundation

/// One of Plexamp's visualisers: its name, its shader, and its config as Plexamp ships it.
///
/// The config is what the visualiser asks of the audio (`data`), how many pixels across
/// it is drawn at (`pixels`), and whether it stays up while paused (`displayWhenIdle`).
/// One that does not flips back to the artwork when the music stops, as in Plexamp.
struct VisualizerProgram: Identifiable, Hashable, Sendable {
    let name: String
    /// The shader's entry point in the app's Metal library.
    let function: String
    let data: VisualizerData
    let pixels: Int
    let displayWhenIdle: Bool

    var id: String { name }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.name == rhs.name }
    func hash(into hasher: inout Hasher) { hasher.combine(name) }

    /// Where the choice is remembered. Plexamp's own key is `ui:visualizerprogram`.
    static let storageKey = "visualizer.program"

    /// Plexamp's Higher Quality Visualizers: the screen's full resolution rather than each
    /// program's own `pixels` across. Off by default, as there.
    static let highQualityKey = "visualizer.highQuality"

    /// For a fresh install, for anyone who has not chosen, and for a remembered name this
    /// build does not have. Plexamp's own fallback is Spectrum; Retrospect is the choice
    /// made for this app.
    static let defaultName = "Retrospect"

    /// In name order, which is the order Plexamp lists and cycles them in.
    static let all: [VisualizerProgram] = [
        VisualizerProgram(
            name: "Freaqy",
            function: "viz_freaqy",
            data: VisualizerData(frequency: true),
            pixels: 512,
            displayWhenIdle: false
        ),
        VisualizerProgram(
            name: "Neutrona",
            function: "viz_neutrona",
            data: VisualizerData(frequency: true, alpha: 0.3),
            pixels: 375,
            displayWhenIdle: false
        ),
        VisualizerProgram(
            name: "Retrospect",
            function: "viz_retrospect",
            data: VisualizerData(frequency: true),
            pixels: 512,
            displayWhenIdle: false
        ),
        VisualizerProgram(
            name: "Rothko",
            function: "viz_rothko",
            data: VisualizerData(frequency: true),
            pixels: 375,
            displayWhenIdle: true
        ),
        VisualizerProgram(
            name: "Spectrum",
            function: "viz_spectrum",
            data: VisualizerData(frequency: true, peaks: true, alpha: 0.3),
            pixels: 512,
            displayWhenIdle: false
        ),
        VisualizerProgram(
            name: "Strings",
            function: "viz_strings",
            data: VisualizerData(frequency: true, alpha: 0.3),
            pixels: 375,
            displayWhenIdle: false
        ),
    ].sorted { $0.name < $1.name }

    static func named(_ name: String) -> VisualizerProgram {
        all.first { $0.name == name } ?? all.first { $0.name == defaultName } ?? all[0]
    }

    /// Swiping left: the next in the list, wrapping round.
    var next: VisualizerProgram {
        let all = Self.all
        let index = all.firstIndex(of: self) ?? 0
        return all[(index + 1) % all.count]
    }

    /// Swiping right.
    var previous: VisualizerProgram {
        let all = Self.all
        let index = all.firstIndex(of: self) ?? 0
        return all[(index - 1 + all.count) % all.count]
    }
}
