import CGtk
import Foundation
import Observation

/// Custom playlist covers, stored on this computer.
///
/// Device-local for the phone's reason: the Subsonic API has no endpoint for setting
/// playlist artwork, so a chosen image cannot reach the server. Squared and scaled to at
/// most 1024 pixels, with any EXIF rotation applied, then kept beside the offline artwork.
@MainActor
@Observable
final class PlaylistArtwork {
    /// Bumped when an image changes, so views observing this re-read the file.
    private(set) var generation = 0

    private let side: Int32 = 1024

    func image(for playlistID: String) -> Texture? {
        Texture(contentsOf: url(for: playlistID))
    }

    func hasCustomImage(for playlistID: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: playlistID).path)
    }

    /// Accepts any image file's bytes, of any size or orientation.
    func setImage(data: Data, for playlistID: String) {
        guard let jpeg = squaredJPEG(from: data) else { return }
        try? jpeg.write(to: url(for: playlistID), options: .atomic)
        generation += 1
    }

    func removeImage(for playlistID: String) {
        try? FileManager.default.removeItem(at: url(for: playlistID))
        generation += 1
    }

    /// Centre-cropped to a square and scaled down. Covers are shown square everywhere, so
    /// cropping once here beats every call site fighting the aspect ratio.
    private func squaredJPEG(from data: Data) -> Data? {
        guard let loader = gdk_pixbuf_loader_new() else { return nil }
        defer { g_object_unref(loader.rawPointer) }
        let written = data.withUnsafeBytes { bytes in
            gdk_pixbuf_loader_write(loader, bytes.baseAddress?.assumingMemoryBound(to: guchar.self), gsize(bytes.count), nil)
        }
        guard written != 0, gdk_pixbuf_loader_close(loader, nil) != 0,
              let loaded = gdk_pixbuf_loader_get_pixbuf(loader),
              let upright = gdk_pixbuf_apply_embedded_orientation(loaded)
        else { return nil }
        defer { g_object_unref(upright.rawPointer) }

        let width = gdk_pixbuf_get_width(upright)
        let height = gdk_pixbuf_get_height(upright)
        let shortest = min(width, height)
        guard shortest > 0,
              let square = gdk_pixbuf_new_subpixbuf(upright, (width - shortest) / 2, (height - shortest) / 2, shortest, shortest)
        else { return nil }
        defer { g_object_unref(square.rawPointer) }

        let target = min(shortest, side)
        guard let scaled = gdk_pixbuf_scale_simple(square, target, target, GDK_INTERP_BILINEAR) else { return nil }
        defer { g_object_unref(scaled.rawPointer) }

        var buffer: UnsafeMutablePointer<gchar>?
        var size: gsize = 0
        var keys: [UnsafeMutablePointer<gchar>?] = [strdup("quality"), nil]
        var values: [UnsafeMutablePointer<gchar>?] = [strdup("85"), nil]
        defer {
            free(keys[0])
            free(values[0])
        }
        guard gdk_pixbuf_save_to_bufferv(scaled, &buffer, &size, "jpeg", &keys, &values, nil) != 0,
              let buffer
        else { return nil }
        defer { g_free(buffer) }
        return Data(bytes: buffer, count: Int(size))
    }

    private func url(for playlistID: String) -> URL {
        let safe = playlistID.replacingOccurrences(of: "/", with: "_")
        return Paths.artwork.appendingPathComponent("playlist-\(safe).jpg")
    }
}
