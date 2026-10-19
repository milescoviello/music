import Foundation
import Observation
import UIKit

/// Cover-art cache.
///
/// Replaces `AsyncImage`, which has no memory cache, cancels on scroll-away and
/// restarts on reappear -- a grey flicker field when scrolling a grid fast. The
/// crucial part is `cached(_:_:)` being **synchronous**: a view can check it during
/// `init` and, on a hit, render with no placeholder and no transition at all.
///
/// Four layers: memory; a **permanent** copy in Application Support of the art of
/// anything downloaded, which iOS cannot purge, so a downloaded album never loses its
/// cover offline; a copy of every cover ever fetched, in Caches, as the server sent it;
/// then the network. The third replaced `URLCache`, which iOS purges as it likes and
/// which kept nothing beyond 512 MB, so covers seen yesterday came from the network
/// again — a blank square in the meantime.
///
/// Covers are also fetched before they are needed: the whole library's, to disk, on
/// Wi-Fi (`warm`), and the next few of a grid's, into memory, as it scrolls (`prefetch`).
@MainActor
@Observable
final class ArtworkStore {
    /// Three sizes only, so both this cache and the server's stay hot.
    enum Size: Int, Sendable, CaseIterable {
        case thumb = 160
        case card = 512
        case full = 1200
    }

    /// One cache per size, so a few player-sized covers cannot push out the hundreds of
    /// thumbnails a list is made of. Sized to the phone: the old 64 MB for everything held
    /// about sixty grid covers, so a grid scrolled back up, or a tab switched back to,
    /// drew most of them again from scratch.
    private let thumbs = NSCache<NSString, UIImage>()
    private let cards = NSCache<NSString, UIImage>()
    private let fulls = NSCache<NSString, UIImage>()
    private let session: URLSession
    // None of this is anything a view should redraw for. Observed, every fetch starting
    // and finishing, and every palette cached while the visualiser draws, was a change
    // notification.
    @ObservationIgnored private var inFlight: [String: Task<UIImage?, Never>] = [:]
    @ObservationIgnored private var signer: SubsonicSigner?
    /// Covers being written for offline use, so an album's tracks, which all ask for the
    /// same cover at once, write it once.
    @ObservationIgnored private var persisting: Set<URL> = []
    @ObservationIgnored private var palettes: [String: Palette] = [:]
    @ObservationIgnored private var warming: Task<Void, Never>?

    init() {
        let ram = Double(ProcessInfo.processInfo.physicalMemory)
        func budget(_ share: Double, cap megabytes: Double) -> Int {
            Int(min(ram * share, megabytes * 1_048_576))
        }
        // A 160-pixel cover is 100 KB decoded, a 512 one 1 MB, a 1200 one 5.8 MB. On an
        // 8 GB phone that is about 1,600 thumbnails, 330 grid covers and 20 player covers,
        // and NSCache gives it all back the moment iOS asks for memory.
        thumbs.totalCostLimit = budget(0.02, cap: 256)
        thumbs.countLimit = 4_000
        cards.totalCostLimit = budget(0.04, cap: 512)
        cards.countLimit = 1_000
        fulls.totalCostLimit = budget(0.015, cap: 160)
        fulls.countLimit = 24

        let configuration = URLSessionConfiguration.default
        // The disk copy below is the cache; a URLCache as well would keep every cover
        // twice, and purge its copy whenever iOS likes.
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 12
        configuration.httpMaximumConnectionsPerHost = 6
        session = URLSession(configuration: configuration)

        // Version 2 cleared covers fetched while Navidrome was rebuilding its artwork,
        // which `returnCacheDataElseLoad` would have kept forever. Version 3 drops the
        // URLCache that held them, now replaced by `Paths.covers`.
        let version = 3
        let stored = UserDefaults.standard.integer(forKey: "artwork.cacheVersion")
        if stored < version {
            URLCache(memoryCapacity: 0, diskCapacity: 0, diskPath: "artwork").removeAllCachedResponses()
            if stored < 2 {
                let saved = (try? FileManager.default.contentsOfDirectory(at: Paths.artwork, includingPropertiesForKeys: nil)) ?? []
                // Not a playlist's chosen photo: that is the user's, not a cache.
                for file in saved where !file.lastPathComponent.hasPrefix("playlist-") {
                    try? FileManager.default.removeItem(at: file)
                }
            }
            UserDefaults.standard.set(version, forKey: "artwork.cacheVersion")
        }
        Task.detached(priority: .background) { Self.trimCovers() }
    }

    /// Keeps the cover cache to a size, oldest written first, once it passes a gigabyte:
    /// the whole library's covers are a few hundred megabytes, and every track's own
    /// cover seen in a list adds to it.
    nonisolated private static func trimCovers() {
        let limit: Int64 = 1_024 * 1_048_576
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: Paths.covers, includingPropertiesForKeys: Array(keys)
        )) ?? []
        var entries = files.compactMap { url -> (url: URL, size: Int64, date: Date)? in
            guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
            return (url, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(Int64(0)) { $0 + $1.size }
        guard total > limit else { return }
        // Down to three quarters, so this is not back at the limit after a day.
        entries.sort { $0.date < $1.date }
        for entry in entries where total > limit * 3 / 4 {
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
        }
    }

    private func memory(_ size: Size) -> NSCache<NSString, UIImage> {
        switch size {
        case .thumb: return thumbs
        case .card: return cards
        case .full: return fulls
        }
    }

    /// Where a size is kept on disk. Keyed by cover id, so the many tracks sharing an
    /// album cover store it once.
    private func fileURL(_ id: String, _ size: Size) -> URL {
        let safe = id.replacingOccurrences(of: "/", with: "_")
        return Paths.artwork.appendingPathComponent("\(safe)@\(size.rawValue).jpg")
    }

    /// Where every fetched cover is kept, in the server's own bytes.
    nonisolated private static func coverURL(_ id: String, _ size: Size) -> URL {
        let safe = id.replacingOccurrences(of: "/", with: "_")
        return Paths.covers.appendingPathComponent("\(safe)@\(size.rawValue)")
    }

    /// Persists a size for offline use. Called when a track is downloaded.
    func persist(id: String?, size: Size) async {
        guard let id else { return }
        let destination = fileURL(id, size)
        guard !persisting.contains(destination),
              !FileManager.default.fileExists(atPath: destination.path)
        else { return }
        persisting.insert(destination)
        defer { persisting.remove(destination) }

        guard let image = await image(for: id, size: size) else { return }

        // The server's own bytes when the cover cache has them, which it does once the
        // image above came from the network; encoded again only when it does not.
        // Off the main actor either way: a JPEG encode of a 1,200-pixel cover is long
        // enough to see, and it ran three times per track of an album being downloaded.
        let cached = Self.coverURL(id, size)
        await Task.detached(priority: .utility) {
            if (try? FileManager.default.copyItem(at: cached, to: destination)) != nil { return }
            guard let data = image.jpegData(compressionQuality: 0.85) else { return }
            try? data.write(to: destination, options: .atomic)
        }.value
    }

    /// Every size a downloaded track needs: rows, grids and the player.
    func persistAll(id: String?) async {
        for size in [Size.thumb, .card, .full] {
            await persist(id: id, size: size)
        }
    }

    /// Bytes held for artwork, offline copies and the cover cache both, for the
    /// settings screen.
    static func diskUsage() -> Int64 {
        let contents = [Paths.artwork, Paths.covers].flatMap { directory in
            (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey]
            )) ?? []
        }
        return contents.reduce(Int64(0)) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return total + Int64(size)
        }
    }

    /// Two colours pulled from a cover, for anything that should feel like it belongs to
    /// the track rather than to the app.
    ///
    /// Saturation-weighted rather than a plain average: averaging a whole sleeve returns
    /// mud roughly every time, because the bright and dark halves cancel. Weighting by
    /// how colourful a pixel is finds the ink instead of the paper.
    struct Palette: Sendable, Equatable {
        var base: UIColor
        var highlight: UIColor
    }

    /// Synchronous, and nil until the artwork itself is in memory — the caller falls back
    /// to the app tint, then gets the real one on the next pass.
    func palette(for id: String?) -> Palette? {
        guard let id else { return nil }
        if let cached = palettes[id] { return cached }
        guard let image = thumbs.object(forKey: key(id, .thumb)) else { return nil }

        guard let palette = Self.extractPalette(from: image) else { return nil }
        palettes[id] = palette
        return palette
    }

    private static func extractPalette(from image: UIImage) -> Palette? {
        // Downsampled to 16x16 first: reading a 160pt image pixel by pixel on the main
        // actor would be visible as a stutter, and sixteen squared is plenty to find a
        // dominant hue.
        let side = 16
        guard let cgImage = image.cgImage else { return nil }

        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(
            data: &pixels,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))

        var weightedRed = 0.0
        var weightedGreen = 0.0
        var weightedBlue = 0.0
        var totalWeight = 0.0
        var brightest = (red: 0.0, green: 0.0, blue: 0.0, score: -1.0)

        for index in stride(from: 0, to: pixels.count, by: 4) {
            let red = Double(pixels[index]) / 255
            let green = Double(pixels[index + 1]) / 255
            let blue = Double(pixels[index + 2]) / 255

            let peak = max(red, green, blue)
            let trough = min(red, green, blue)
            let saturation = peak <= 0 ? 0 : (peak - trough) / peak

            // Near-black and near-white pixels say nothing about a sleeve's colour.
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

        guard totalWeight > 0 else { return nil }

        let base = UIColor(
            red: weightedRed / totalWeight,
            green: weightedGreen / totalWeight,
            blue: weightedBlue / totalWeight,
            alpha: 1
        )

        // Lifted well clear of the base so a gradient between them actually reads as a
        // gradient on a dark background.
        let highlight = UIColor(
            red: min(brightest.red * 1.25 + 0.15, 1),
            green: min(brightest.green * 1.25 + 0.15, 1),
            blue: min(brightest.blue * 1.25 + 0.15, 1),
            alpha: 1
        )

        return Palette(base: Self.lifted(base), highlight: highlight)
    }

    /// A sleeve that is nearly black would otherwise give bars that cannot be seen
    /// against a black backdrop.
    private static func lifted(_ colour: UIColor) -> UIColor {
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        guard colour.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        else { return colour }

        return UIColor(
            hue: hue,
            saturation: max(saturation, 0.45),
            brightness: max(brightness, 0.55),
            alpha: 1
        )
    }

    func configure(signer: SubsonicSigner?) {
        self.signer = signer
        if signer == nil {
            for cache in [thumbs, cards, fulls] { cache.removeAllObjects() }
            inFlight.removeAll()
            palettes.removeAll()
            warming?.cancel()
            warming = nil
        }
    }

    private func key(_ id: String, _ size: Size) -> NSString {
        "\(id)@\(size.rawValue)" as NSString
    }

    /// Synchronous memory-cache probe. This is what removes the flicker.
    func cached(_ id: String?, _ size: Size) -> UIImage? {
        guard let id else { return nil }
        return memory(size).object(forKey: key(id, size))
    }

    /// The same cover at another size, while the one asked for loads: the grid's cover
    /// in the player until the full one arrives, a row's thumbnail in a grid. Softer for a
    /// moment beats a grey square. Larger sizes first, since they scale down cleanly.
    func cachedStandIn(_ id: String?, for size: Size) -> UIImage? {
        guard let id else { return nil }
        let others = Size.allCases.filter { $0 != size }.sorted { $0.rawValue > $1.rawValue }
        for other in others {
            if let image = memory(other).object(forKey: key(id, other)) { return image }
        }
        return nil
    }

    func url(for id: String?, size: Size) -> URL? {
        guard let id, let signer else { return nil }
        return signer.url("getCoverArt.view", ["id": id, "size": String(size.rawValue)])
    }

    /// Loads and decodes off the main actor. Concurrent requests for the same key
    /// share one task, so scrolling a grid up and down does not issue duplicates.
    func image(for id: String?, size: Size) async -> UIImage? {
        guard let id else { return nil }

        let cache = memory(size)
        if let hit = cache.object(forKey: key(id, size)) { return hit }

        let cacheKey = "\(id)@\(size.rawValue)"
        if let existing = inFlight[cacheKey] { return await existing.value }

        let kept = fileURL(id, size)
        let copy = Self.coverURL(id, size)
        let remote = url(for: id, size: size)

        let task = Task<UIImage?, Never> { [session] in
            // Disk before network, so offline art appears and nothing seen before is
            // fetched again. Reading and decoding are expensive either way, so both paths
            // do them off the main actor -- this task itself is on it.
            //
            // Bound to a local first: a trailing closure inside an `if let` condition
            // cannot be parsed -- it reads as the `if` body.
            let stored = await Task.detached(priority: .userInitiated) {
                ((try? Data(contentsOf: kept)) ?? (try? Data(contentsOf: copy))).flatMap(Self.decoded)
            }.value
            if let stored { return stored }

            guard let remote, let data = await Self.fetch(remote, session: session) else { return nil }

            return await Task.detached(priority: .userInitiated) {
                // Kept as sent, before decoding, so the next launch reads it from disk.
                try? data.write(to: copy, options: .atomic)
                return Self.decoded(data)
            }.value
        }
        inFlight[cacheKey] = task

        let image = await task.value
        inFlight[cacheKey] = nil

        if let image {
            let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
            cache.setObject(image, forKey: key(id, size), cost: cost)
        }
        return image
    }

    /// A cover's bytes, or nil for anything that is not an image: Navidrome answers a
    /// failure with an error page, which must not be kept as the cover.
    nonisolated private static func fetch(_ url: URL, session: URLSession) async -> Data? {
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) ?? true,
              !(response.mimeType ?? "").contains("json"),
              !(response.mimeType ?? "").contains("xml"),
              !data.isEmpty
        else { return nil }
        return data
    }

    /// Loads the covers a grid is about to show into memory, so a fast scroll finds them
    /// there instead of drawing a placeholder first. Cheap for covers already loaded or
    /// loading.
    func prefetch(_ ids: some Sequence<String?>, size: Size) {
        let cache = memory(size)
        for case let id? in ids where cache.object(forKey: key(id, size)) == nil
            && inFlight["\(id)@\(size.rawValue)"] == nil {
            Task(priority: .utility) { _ = await image(for: id, size: size) }
        }
    }

    /// Fetches covers to disk ahead of time, a few at a time at low priority, so that the
    /// first sight of any of them is a disk read rather than a request. To disk only: into
    /// memory, the whole library would push out what is on screen.
    ///
    /// Called with the whole library once it is loaded, on Wi-Fi. Covers already on disk
    /// cost a file check; a second call while one is running is ignored.
    func warm(_ ids: [String], sizes: [Size]) {
        guard warming == nil, signer != nil else { return }
        var wanted: [(file: URL, remote: URL)] = []
        for id in Set(ids) {
            for size in sizes {
                guard let remote = url(for: id, size: size) else { continue }
                wanted.append((Self.coverURL(id, size), remote))
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
                        guard !Task.isCancelled, let data = await Self.fetch(item.remote, session: session) else { return }
                        try? data.write(to: item.file, options: .atomic)
                    }
                    return true
                }
                // Four at once: quick enough to cover a few thousand albums in a minute
                // or two on Wi-Fi, gentle enough on the server and on what is on screen.
                for _ in 0..<4 where addNext() {}
                for await _ in group {
                    if Task.isCancelled { break }
                    _ = addNext()
                }
            }
            await MainActor.run { self.warming = nil }
        }
    }

    /// An image that is decoded already, not merely parsed.
    ///
    /// `UIImage(data:)` reads the header and nothing more; the JPEG itself was being
    /// decompressed on the main thread the first time the image was drawn, so every
    /// cover arriving in a scrolling grid, and every new track's full-size art in the
    /// player, cost the main thread its decode. Preparing it here does that work on the
    /// thread that already has the bytes.
    nonisolated private static func decoded(_ data: Data) -> UIImage? {
        guard let image = UIImage(data: data) else { return nil }
        return image.preparingForDisplay() ?? image
    }
}
