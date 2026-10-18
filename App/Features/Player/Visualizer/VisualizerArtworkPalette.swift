import UIKit

/// A cover's 32 visualiser colours, worked out once per cover.
///
/// Plexamp asks its server for the cover as a 150×150 PNG and runs ColorCube over that;
/// this draws our thumb at the same size so the histogram sees the same pixels, give or
/// take the resampler.
@MainActor
enum VisualizerArtworkPalette {
    private static var cache: [String: [VisualizerPalette.RGB]] = [:]
    private static let side = 150

    static func colours(for coverArt: String?, artwork: ArtworkStore) async -> [VisualizerPalette.RGB]? {
        guard let coverArt else { return nil }
        if let cached = cache[coverArt] { return cached }

        guard let image = await artwork.image(for: coverArt, size: .thumb),
              let bitmap = bitmap(of: image)
        else { return nil }

        // A few milliseconds of histogram work: off the main actor, where a frame of
        // the visualiser is waiting.
        let colours = await Task.detached(priority: .utility) {
            VisualizerPalette.gradient(fromQuadrantColours: ColorCube.quadrantColours(
                pixels: bitmap.pixels, width: bitmap.width, height: bitmap.height
            ))
        }.value
        guard colours.count == VisualizerPalette.size else { return nil }

        if cache.count > 256 { cache.removeAll() }
        cache[coverArt] = colours
        return colours
    }

    /// RGBA, top row first, the long side 150.
    private static func bitmap(of image: UIImage) -> (pixels: [UInt8], width: Int, height: Int)? {
        guard let cgImage = image.cgImage, cgImage.width > 0, cgImage.height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }

        let aspect = Double(cgImage.width) / Double(cgImage.height)
        let width = aspect >= 1 ? side : max(1, Int((Double(side) * aspect).rounded()))
        let height = aspect >= 1 ? max(1, Int((Double(side) / aspect).rounded())) : side

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? (pixels, width, height) : nil
    }
}
