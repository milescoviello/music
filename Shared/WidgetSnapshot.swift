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

    var title: String?
    var artist: String?
    var album: String?
    var isPlaying: Bool = false
    var mixes: [Mix] = []
    var updated: Date = .now

    static let fileName = "widget.json"
    static let coverName = "widget-cover.jpg"

    static func mixCoverName(_ number: Int) -> String { "widget-mix-\(number).jpg" }

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
