import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Observation

/// Cover-art cache: the phone's three layers, with textures instead of `UIImage`s.
///
/// Memory, then disk, then the network. The disk has two parts, as on the phone: the
/// **permanent** copies in `Paths.artwork` that a download keeps next to its music, and a
/// cache of everything else seen, in Caches, that can be thrown away. The cache replaces
/// `URLCache`, whose disk side Linux Foundation does not reliably keep.
///
/// `cached(_:_:)` is synchronous for the same reason as on the phone: a row bound to a
/// cover already in memory draws it at once, with no placeholder and no flicker.
@MainActor
@Observable
final class ArtworkStore {
    /// Three sizes only, so both this cache and the server's stay hot.
    enum Size: Int, Sendable {
        case thumb = 160
        case card = 512
        case full = 1200
    }

    @ObservationIgnored private let memory = NSCache<NSString, Texture>()
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private var inFlight: [String: Task<Texture?, Never>] = [:]
    @ObservationIgnored private var signer: SubsonicSigner?
    @ObservationIgnored private var warming: Task<Void, Never>?

    init() {
        memory.countLimit = 400
        memory.totalCostLimit = 192 * 1024 * 1024

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 12
        session = URLSession(configuration: configuration)

        try? FileManager.default.createDirectory(at: Self.cacheDirectory, withIntermediateDirectories: true)
        Task.detached(priority: .background) { Self.trimCache() }
    }

    /// Seen covers, not kept ones: can be emptied at any time and refetched.
    private nonisolated static var cacheDirectory: URL {
        Paths.caches.appendingPathComponent("Artwork", isDirectory: true)
    }

    private nonisolated static func safe(_ id: String) -> String {
        id.replacingOccurrences(of: "/", with: "_")
    }

    /// Where a size is kept for offline use. Keyed by cover id, so the many tracks
    /// sharing an album cover store it once.
    private func fileURL(_ id: String, _ size: Size) -> URL {
        Paths.artwork.appendingPathComponent("\(Self.safe(id))@\(size.rawValue).jpg")
    }

    private func cacheURL(_ id: String, _ size: Size) -> URL {
        Self.cacheDirectory.appendingPathComponent("\(Self.safe(id))@\(size.rawValue)")
    }

    /// Persists a size for offline use. Called when a track is downloaded.
    ///
    /// The server's own bytes are kept rather than a re-encoding: Navidrome already scaled
    /// them to this size, and a second JPEG pass only loses quality.
    func persist(id: String?, size: Size) async {
        guard let id else { return }
        let destination = fileURL(id, size)
        guard !FileManager.default.fileExists(atPath: destination.path) else { return }
        guard let data = await data(for: id, size: size) else { return }
        try? data.write(to: destination, options: .atomic)
    }

    /// Every size a downloaded track needs: rows, grids and the player.
    func persistAll(id: String?) async {
        for size in [Size.thumb, .card, .full] {
            await persist(id: id, size: size)
        }
    }

    /// Bytes held for offline artwork, for the settings screen.
    static func diskUsage() -> Int64 {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: Paths.artwork,
            includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        return contents.reduce(Int64(0)) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return total + Int64(size)
        }
    }

    // MARK: - Palette

    /// An sRGB colour, 0...1 per channel.
    struct RGB: Sendable, Equatable {
        var red: Double
        var green: Double
        var blue: Double

        /// For CSS and Pango markup.
        var hex: String {
            func byte(_ value: Double) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
            return String(format: "#%02x%02x%02x", byte(red), byte(green), byte(blue))
        }
    }

    /// Two colours pulled from a cover, for anything that should feel like it belongs to
    /// the track rather than to the app. Saturation-weighted, exactly as on the phone:
    /// averaging a whole sleeve returns mud, because the bright and dark halves cancel.
    struct Palette: Sendable, Equatable {
        var base: RGB
        var highlight: RGB
    }

    private var palettes: [String: Palette] = [:]

    /// Synchronous, and nil until the artwork itself is in memory — the caller falls back
    /// to the app tint, then gets the real one on the next pass.
    func palette(for id: String?) -> Palette? {
        guard let id else { return nil }
        if let cached = palettes[id] { return cached }
        guard let texture = memory.object(forKey: key(id, .thumb))
            ?? memory.object(forKey: key(id, .card))
            ?? memory.object(forKey: key(id, .full))
        else { return nil }
        guard let palette = Self.extractPalette(from: texture) else { return nil }
        palettes[id] = palette
        return palette
    }

    private static func extractPalette(from texture: Texture) -> Palette? {
        let (pixels, stride) = texture.pixels()
        let width = texture.width
        let height = texture.height
        guard width > 0, height > 0 else { return nil }

        // A 16×16 grid of samples, as the phone downsamples to: plenty to find a dominant
        // hue, and cheap enough for the main actor.
        let side = 16
        var weightedRed = 0.0
        var weightedGreen = 0.0
        var weightedBlue = 0.0
        var totalWeight = 0.0
        var brightest = (red: 0.0, green: 0.0, blue: 0.0, score: -1.0)

        for row in 0..<side {
            for column in 0..<side {
                let x = min(width - 1, column * width / side + width / (side * 2))
                let y = min(height - 1, row * height / side + height / (side * 2))
                let index = y * stride + x * 4
                // Premultiplied BGRA; covers are opaque, so the alpha divide is moot.
                let blue = Double(pixels[index]) / 255
                let green = Double(pixels[index + 1]) / 255
                let red = Double(pixels[index + 2]) / 255

                let peak = max(red, green, blue)
                let trough = min(red, green, blue)
                let saturation = peak <= 0 ? 0 : (peak - trough) / peak
                let usefulness = saturation * (1 - abs(peak - 0.6) * 0.8)
                let weight = max(usefulness, 0.02)

                weightedRed += red * weight
                weightedGreen += green * weight
                weightedBlue += blue * weight
                totalWeight += weight

                let score = saturation * peak
                if score > brightest.score {
                    brightest = (red, green, blue, score)
                }
            }
        }

        guard totalWeight > 0 else { return nil }
        let base = RGB(red: weightedRed / totalWeight, green: weightedGreen / totalWeight, blue: weightedBlue / totalWeight)
        let highlight = RGB(
            red: min(brightest.red * 1.25 + 0.15, 1),
            green: min(brightest.green * 1.25 + 0.15, 1),
            blue: min(brightest.blue * 1.25 + 0.15, 1)
        )
        return Palette(base: lifted(base), highlight: highlight)
    }

    /// A sleeve that is nearly black would otherwise give bars that cannot be seen
    /// against a black backdrop.
    private static func lifted(_ colour: RGB) -> RGB {
        let peak = max(colour.red, colour.green, colour.blue)
        let trough = min(colour.red, colour.green, colour.blue)
        let delta = peak - trough
        var hue = 0.0
        if delta > 0 {
            if peak == colour.red {
                hue = ((colour.green - colour.blue) / delta).truncatingRemainder(dividingBy: 6)
            } else if peak == colour.green {
                hue = (colour.blue - colour.red) / delta + 2
            } else {
                hue = (colour.red - colour.green) / delta + 4
            }
            hue /= 6
            if hue < 0 { hue += 1 }
        }
        let saturation = max(peak <= 0 ? 0 : delta / peak, 0.45)
        let brightness = max(peak, 0.55)
        return hsb(hue: hue, saturation: saturation, brightness: brightness)
    }

    private static func hsb(hue: Double, saturation: Double, brightness: Double) -> RGB {
        let sector = hue * 6
        let index = Int(sector) % 6
        let fraction = sector - Double(Int(sector))
        let p = brightness * (1 - saturation)
        let q = brightness * (1 - saturation * fraction)
        let t = brightness * (1 - saturation * (1 - fraction))
        switch index {
        case 0: return RGB(red: brightness, green: t, blue: p)
        case 1: return RGB(red: q, green: brightness, blue: p)
        case 2: return RGB(red: p, green: brightness, blue: t)
        case 3: return RGB(red: p, green: q, blue: brightness)
        case 4: return RGB(red: t, green: p, blue: brightness)
        default: return RGB(red: brightness, green: p, blue: q)
        }
    }

    // MARK: - Loading

    func configure(signer: SubsonicSigner?) {
        self.signer = signer
        if signer == nil {
            memory.removeAllObjects()
            inFlight.removeAll()
            palettes.removeAll()
        }
    }

    private func key(_ id: String, _ size: Size) -> NSString {
        NSString(string: "\(id)@\(size.rawValue)")
    }

    /// Synchronous memory-cache probe. This is what removes the flicker.
    func cached(_ id: String?, _ size: Size) -> Texture? {
        guard let id else { return nil }
        return memory.object(forKey: key(id, size))
    }

    func url(for id: String?, size: Size) -> URL? {
        guard let id, let signer else { return nil }
        return signer.url("getCoverArt.view", ["id": id, "size": String(size.rawValue)])
    }

    /// The encoded bytes for a cover: kept copy, then cache, then server.
    private func data(for id: String, size: Size) async -> Data? {
        let kept = fileURL(id, size)
        let cache = cacheURL(id, size)
        let remote = url(for: id, size: size)
        let session = session
        return await Task.detached(priority: .userInitiated) { () -> Data? in
            if let data = try? Data(contentsOf: kept) { return data }
            if let data = try? Data(contentsOf: cache) { return data }
            guard let remote,
                  let (data, response) = try? await session.data(from: remote),
                  (response as? HTTPURLResponse)?.statusCode ?? 200 < 300,
                  !Self.isErrorBody(data)
            else { return nil }
            try? data.write(to: cache, options: .atomic)
            return data
        }.value
    }

    /// Navidrome answers a missing cover with a JSON or XML error, not an image.
    private nonisolated static func isErrorBody(_ data: Data) -> Bool {
        guard let first = data.first else { return true }
        return first == UInt8(ascii: "{") || first == UInt8(ascii: "<")
    }

    /// Loads and decodes off the main actor. Concurrent requests for the same key share
    /// one task, so scrolling a grid up and down does not issue duplicates.
    func image(for id: String?, size: Size) async -> Texture? {
        guard let id else { return nil }
        if let hit = memory.object(forKey: key(id, size)) { return hit }

        let cacheKey = "\(id)@\(size.rawValue)"
        if let existing = inFlight[cacheKey] { return await existing.value }

        let task = Task<Texture?, Never> {
            guard let data = await data(for: id, size: size) else { return nil }
            return await Task.detached(priority: .userInitiated) { Texture(data: data) }.value
        }
        inFlight[cacheKey] = task
        let texture = await task.value
        inFlight[cacheKey] = nil

        if let texture {
            memory.setObject(texture, forKey: key(id, size), cost: texture.width * texture.height * 4)
        }
        return texture
    }

    /// Loads the covers a list is about to show into memory, as the iPhone's does, so a
    /// fast scroll finds them there.
    func prefetch(_ ids: some Sequence<String?>, size: Size) {
        for case let id? in ids where memory.object(forKey: key(id, size)) == nil
            && inFlight["\(id)@\(size.rawValue)"] == nil {
            Task { _ = await image(for: id, size: size) }
        }
    }

    /// The whole library's covers to the disk cache ahead of time, a few at once and at
    /// low priority, as the iPhone's does: no cover is first seen from the network.
    func warm(_ ids: [String], sizes: [Size]) {
        guard warming == nil, signer != nil else { return }
        var wanted: [(file: URL, remote: URL)] = []
        for id in Set(ids) {
            for size in sizes {
                guard let remote = url(for: id, size: size) else { continue }
                wanted.append((cacheURL(id, size), remote))
            }
        }
        let session = session
        warming = Task.detached(priority: .background) {
            let missing = wanted.filter { !FileManager.default.fileExists(atPath: $0.file.path) }
            await withTaskGroup(of: Void.self) { group in
                var next = missing.makeIterator()
                func addNext() -> Bool {
                    guard let item = next.next() else { return false }
                    group.addTask {
                        guard !Task.isCancelled,
                              let (data, response) = try? await session.data(from: item.remote),
                              (response as? HTTPURLResponse)?.statusCode ?? 200 < 300,
                              !Self.isErrorBody(data)
                        else { return }
                        try? data.write(to: item.file, options: .atomic)
                    }
                    return true
                }
                for _ in 0..<4 where addNext() {}
                for await _ in group {
                    if Task.isCancelled { break }
                    _ = addNext()
                }
            }
            await MainActor.run { self.warming = nil }
        }
    }

    /// Keeps the seen-covers cache to a size: oldest first, past half a gigabyte.
    private nonisolated static func trimCache() {
        let limit: Int64 = 512 * 1024 * 1024
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: cacheDirectory, includingPropertiesForKeys: keys
        )) ?? []
        var entries = files.compactMap { url -> (URL, Int64, Date)? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(Int64(0)) { $0 + $1.1 }
        guard total > limit else { return }
        entries.sort { $0.2 < $1.2 }
        for (url, size, _) in entries where total > limit {
            try? FileManager.default.removeItem(at: url)
            total -= size
        }
    }
}
