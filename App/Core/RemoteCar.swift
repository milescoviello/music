import Foundation

// The car's side of the remote protocol (`RemoteControl`, "The car."): what the phone
// serves a head unit that can reach nothing but the phone.

/// The phone's monotonic clock, `ProcessInfo.systemUptime`, for the car to measure its own
/// against, so that a song position and the moment it is heard mean the same on both.
struct RemoteClock: Codable, Equatable, Sendable {
    var uptime: Double
}

/// The colours the player takes from a cover: `CoverColours.pick`'s three pools, the accent
/// `CoverTint` lends the app, and which of the player's backgrounds is chosen.
struct RemoteCarPalette: Codable, Equatable, Sendable {
    var pools: [[Int]]
    var accent: [Int]
    /// `PlayerSettings.Background`'s raw value.
    var background: String?
}

/// The lyrics as the lyrics screen has them: timed lines, and where there are, word timing,
/// a translation and a romanization. Times are milliseconds from the start of the track,
/// with the set's offset already applied.
struct RemoteCarLyrics: Codable, Equatable, Sendable {
    struct Word: Codable, Equatable, Sendable {
        var start: Int
        var text: String
    }

    struct Line: Codable, Equatable, Sendable {
        var start: Int?
        var end: Int?
        var text: String
        var words: [Word]?
        var translation: String?
        var romanized: String?
    }

    var synced: Bool
    var lines: [Line]
}

/// The loudness-shaped seekbar's bars, 0...1.
struct RemoteCarLevels: Codable, Equatable, Sendable {
    var levels: [Float]
}

/// One page of the library. A `folder` is opened by its id as a path; anything else by
/// `<kind>/<id>`, and played with the `playItem` command.
struct RemoteCarBrowse: Codable, Equatable, Sendable {
    struct Item: Codable, Equatable, Sendable {
        /// folder, artist, album, playlist or song
        var kind: String
        var id: String
        var title: String
        var subtitle: String?
        var cover: String?
    }

    var title: String
    var items: [Item]
}

/// What only the phone's own app can answer: images, the spectrum, lyrics, the library.
/// The iPhone app provides one (`CarProvider`); the desktop has none, and its routes answer
/// 404, which is the car's cue to do without.
@MainActor
protocol RemoteCarProvider: AnyObject {
    /// The cover, `size`×`size`, as RGB: three bytes a pixel, rows top to bottom.
    func art(coverArt: String, size: Int) async -> Data?
    func palette(coverArt: String) async -> RemoteCarPalette?
    func lyrics(songID: String) async -> RemoteCarLyrics?
    func levels(songID: String) async -> [Float]?
    func browse(path: String) async -> RemoteCarBrowse?
    func playItem(kind: String, id: String, index: Int, shuffled: Bool) async -> Bool
    /// Seconds between the phone having the audio and the speakers playing it: Bluetooth's
    /// delay, as the system reports it for the route in use.
    var outputLatency: Double { get }
    /// The newest spectrum: where in the song its samples were, and 64 bands, 0...255.
    func spectrum() -> (mediaTime: Double, bands: [UInt8])?
}

/// The car's drives, kept on the phone as it sends them.
enum RemoteCarTrips {
    static var folder: URL { Paths.root.appendingPathComponent("CarTrips", isDirectory: true) }

    /// A drive's id is its UTC start, `YYYYMMDD-HHMMSS`; anything else is refused, since it
    /// becomes a file name.
    static func isValid(_ id: String) -> Bool {
        id.count == 15 && id.enumerated().allSatisfy { index, c in index == 8 ? c == "-" : c.isASCII && c.isNumber }
    }

    static func save(_ csv: Data, id: String) -> Bool {
        guard isValid(id) else { return false }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try csv.write(to: folder.appendingPathComponent("\(id).csv"), options: .atomic)
            return true
        } catch {
            return false
        }
    }
}

enum RemoteCarSpectrum {
    /// The car reads 30 a second at most; more is Wi-Fi spent for nothing.
    static let interval: Duration = .milliseconds(33)

    /// One `spectrum` event: the song position of its samples, the 64 bands as hex, then
    /// the song position being heard, the phone's clock at that moment, and the rate. The
    /// last three are the state's timing again, a few times a second, so the car never
    /// drifts from the music between `state` events.
    static func event(mediaTime: Double, bands: [UInt8], heard: Double, at uptime: Double, rate: Double) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var hex = [UInt8]()
        hex.reserveCapacity(bands.count * 2)
        for band in bands {
            hex.append(digits[Int(band >> 4)])
            hex.append(digits[Int(band & 15)])
        }
        let data = String(format: "%.4f ", mediaTime) + String(decoding: hex, as: UTF8.self)
            + String(format: " %.4f %.4f %.3f", heard, uptime, rate)
        return "event: spectrum\ndata: \(data)\n\n"
    }
}
