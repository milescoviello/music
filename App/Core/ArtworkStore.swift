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
/// Three layers, and the third is the reason this file changed: memory, then a
/// **permanent** copy in Application Support, then the network. `URLCache` alone was not
/// enough — iOS purges it under storage pressure, so a downloaded album could keep its
/// audio and lose its cover, which offline is unrecoverable. Anything downloaded gets
/// its art kept deliberately, next to the music.
@MainActor
@Observable
final class ArtworkStore {
    /// Three sizes only, so both this cache and the server's stay hot.
    enum Size: Int, Sendable {
        case thumb = 160
        case card = 512
        case full = 1200
    }

    private let memory = NSCache<NSString, UIImage>()
    private let session: URLSession
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    private var signer: SubsonicSigner?

    init() {
        memory.countLimit = 300
        memory.totalCostLimit = 64 * 1024 * 1024

        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(
            memoryCapacity: 16 * 1024 * 1024,
            diskCapacity: 512 * 1024 * 1024,
            diskPath: "artwork"
        )
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.timeoutIntervalForRequest = 12
        session = URLSession(configuration: configuration)

        // Covers fetched while Navidrome was rebuilding its artwork came back wrong, and
        // `returnCacheDataElseLoad` keeps whatever it got forever. Cleared once, so every
        // cover is fetched again from the server as it is now.
        let version = 2
        if UserDefaults.standard.integer(forKey: "artwork.cacheVersion") < version {
            configuration.urlCache?.removeAllCachedResponses()
            let saved = (try? FileManager.default.contentsOfDirectory(at: Paths.artwork, includingPropertiesForKeys: nil)) ?? []
            for file in saved { try? FileManager.default.removeItem(at: file) }
            UserDefaults.standard.set(version, forKey: "artwork.cacheVersion")
        }
    }

    /// Where a size is kept on disk. Keyed by cover id, so the many tracks sharing an
    /// album cover store it once.
    private func fileURL(_ id: String, _ size: Size) -> URL {
        let safe = id.replacingOccurrences(of: "/", with: "_")
        return Paths.artwork.appendingPathComponent("\(safe)@\(size.rawValue).jpg")
    }

    /// Persists a size for offline use. Called when a track is downloaded.
    func persist(id: String?, size: Size) async {
        guard let id else { return }
        let destination = fileURL(id, size)
        guard !FileManager.default.fileExists(atPath: destination.path) else { return }

        guard let image = await image(for: id, size: size),
              let data = image.jpegData(compressionQuality: 0.85)
        else { return }

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

    private var palettes: [String: Palette] = [:]

    /// Synchronous, and nil until the artwork itself is in memory — the caller falls back
    /// to the app tint, then gets the real one on the next pass.
    func palette(for id: String?) -> Palette? {
        guard let id else { return nil }
        if let cached = palettes[id] { return cached }
        guard let image = memory.object(forKey: key(id, .thumb)) else { return nil }

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
            memory.removeAllObjects()
            inFlight.removeAll()
            palettes.removeAll()
        }
    }

    private func key(_ id: String, _ size: Size) -> NSString {
        "\(id)@\(size.rawValue)" as NSString
    }

    /// Synchronous memory-cache probe. This is what removes the flicker.
    func cached(_ id: String?, _ size: Size) -> UIImage? {
        guard let id else { return nil }
        return memory.object(forKey: key(id, size))
    }

    func url(for id: String?, size: Size) -> URL? {
        guard let id, let signer else { return nil }
        return signer.url("getCoverArt.view", ["id": id, "size": String(size.rawValue)])
    }

    /// Loads and decodes off the main actor. Concurrent requests for the same key
    /// share one task, so scrolling a grid up and down does not issue duplicates.
    func image(for id: String?, size: Size) async -> UIImage? {
        guard let id else { return nil }

        if let hit = memory.object(forKey: key(id, size)) { return hit }

        let cacheKey = "\(id)@\(size.rawValue)"
        if let existing = inFlight[cacheKey] { return await existing.value }

        let file = fileURL(id, size)
        let remote = url(for: id, size: size)

        let task = Task<UIImage?, Never> { [session] in
            // Disk before network, so offline art appears and an online launch does not
            // re-fetch what is already kept. Decoding is expensive either way, so both
            // paths do it off the main actor.
            if let data = try? Data(contentsOf: file) {
                // Bound to a local first: a trailing closure inside an `if let`
                // condition cannot be parsed -- it reads as the `if` body.
                let decoded = await Task.detached(priority: .userInitiated) {
                    UIImage(data: data)
                }.value
                if let decoded { return decoded }
            }

            guard let remote,
                  let (data, _) = try? await session.data(from: remote)
            else { return nil }

            return await Task.detached(priority: .userInitiated) {
                UIImage(data: data)
            }.value
        }
        inFlight[cacheKey] = task

        let image = await task.value
        inFlight[cacheKey] = nil

        if let image {
            let cost = Int(image.size.width * image.size.height * 4)
            memory.setObject(image, forKey: key(id, size), cost: cost)
        }
        return image
    }
}
