import Foundation

/// What the widgets show, written by the app into the shared container (`AppGroup`): the
/// song playing, and today's Made for You. A small JSON file and a few covers; the widgets
/// only read.
struct WidgetSnapshot: Codable, Sendable, Equatable {
    struct Mix: Codable, Sendable, Equatable {
        /// Its place on the Made for You shelf, from 1: what playing it asks for.
        var number: Int
        var title: String
        var subtitle: String
    }

    /// A pinned playlist, shown when nothing is playing: a tap plays it.
    struct Pinned: Codable, Sendable, Equatable {
        var id: String
        var name: String
    }

    var title: String?
    var artist: String?
    var album: String?
    var isPlaying: Bool = false
    var mixes: [Mix] = []
    /// A song coming up, for the large widget's Up Next.
    struct Line: Codable, Sendable, Equatable {
        var title: String
        var artist: String?
    }

    // Everything below is optional, so a snapshot written by an older build still decodes.

    var pinned: [Pinned]?
    /// Where the song was (`elapsed` seconds in) at `anchor`, how long it is, and how fast
    /// it plays (0 while paused): enough for the widget's progress bar to run on its own.
    var elapsed: Double?
    var duration: Double?
    var rate: Double?
    var anchor: Date?
    /// The Linux player's codec line: "FLAC · 24/96", the song's stars, its heart.
    var quality: String?
    var rating: Int?
    var isFavourite: Bool?
    var upNext: [Line]?
    /// The playing song's three cover colours (0...255 a channel) and its accent (0...1),
    /// as the app draws them behind its pages (`CoverColours`).
    var pools: [[Double]]?
    var accent: [Double]?

    /// When the song started and will end, at the rate it plays; nil while paused or
    /// before anything is known.
    var playingSpan: ClosedRange<Date>? {
        guard isPlaying, let elapsed, let duration, let anchor, let rate, rate > 0, duration > 0 else { return nil }
        let start = anchor.addingTimeInterval(-elapsed / rate)
        return start...start.addingTimeInterval(duration / rate)
    }

    /// How far through, 0...1, for a paused song.
    var fraction: Double {
        guard let elapsed, let duration, duration > 0 else { return 0 }
        return min(max(elapsed / duration, 0), 1)
    }
    var updated: Date = .now

    static let fileName = "widget.json"
    static let coverName = "widget-cover.jpg"

    static func mixCoverName(_ number: Int) -> String { "widget-mix-\(number).jpg" }

    /// The cover-colour backdrop, drawn small by the app: square for the small and large
    /// widgets, wide for the medium ones.
    static let groundSquareName = "widget-ground-square.png"
    static let groundWideName = "widget-ground-wide.png"

    /// By place, from 1, as the mixes' are.
    static func pinnedCoverName(_ number: Int) -> String { "widget-pinned-\(number).jpg" }

    static func load() -> WidgetSnapshot? {
        guard let url = AppGroup.container?.appendingPathComponent(fileName),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    func save() {
        guard let url = AppGroup.container?.appendingPathComponent(Self.fileName),
              let data = try? JSONEncoder().encode(self)
        else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func image(_ name: String) -> Data? {
        guard let url = AppGroup.container?.appendingPathComponent(name) else { return nil }
        return try? Data(contentsOf: url)
    }

    static func setImage(_ data: Data?, _ name: String) {
        guard let url = AppGroup.container?.appendingPathComponent(name) else { return }
        if let data {
            try? data.write(to: url, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
