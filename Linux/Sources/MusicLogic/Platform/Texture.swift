import CGtk
import Foundation

/// A decoded image, ready to draw: a `GdkTexture`, which is immutable and safe to share
/// across threads, held with one reference that Swift owns.
///
/// What `UIImage` is to the phone's code. Decoding happens off the main actor; the
/// texture is then handed to a `GtkPicture` or drawn with cairo as is.
final class Texture: @unchecked Sendable {
    let pointer: OpaquePointer

    /// Takes over a reference the caller already owns.
    init(adopting pointer: OpaquePointer) {
        self.pointer = pointer
    }

    deinit {
        g_object_unref(pointer.rawPointer)
    }

    /// Decodes PNG, JPEG or anything else gdk-pixbuf knows. Nil for bytes that are not an
    /// image — Navidrome's error body, a truncated file.
    convenience init?(data: Data) {
        guard !data.isEmpty else { return nil }
        let bytes = data.withUnsafeBytes { buffer in
            g_bytes_new(buffer.baseAddress, gsize(buffer.count))
        }
        defer { g_bytes_unref(bytes) }
        var error: UnsafeMutablePointer<GError>?
        guard let texture = gdk_texture_new_from_bytes(bytes, &error) else {
            if let error { g_error_free(error) }
            return nil
        }
        self.init(adopting: texture)
    }

    convenience init?(contentsOf url: URL) {
        guard let data = try? Data(contentsOf: url) else { return nil }
        self.init(data: data)
    }

    var width: Int { Int(gdk_texture_get_width(pointer)) }
    var height: Int { Int(gdk_texture_get_height(pointer)) }

    /// The same object as a `GdkPaintable`, for `gtk_picture_set_paintable`.
    var paintable: OpaquePointer { pointer }

    /// Premultiplied BGRA rows, top to bottom — `gdk_texture_download`'s format.
    func pixels() -> (bytes: [UInt8], stride: Int) {
        let stride = width * 4
        var bytes = [UInt8](repeating: 0, count: stride * height)
        bytes.withUnsafeMutableBufferPointer { buffer in
            gdk_texture_download(pointer, buffer.baseAddress, gsize(stride))
        }
        return (bytes, stride)
    }

    func pngData() -> Data? {
        guard let bytes = gdk_texture_save_to_png_bytes(pointer) else { return nil }
        defer { g_bytes_unref(bytes) }
        var size: gsize = 0
        guard let base = g_bytes_get_data(bytes, &size) else { return nil }
        return Data(bytes: base, count: Int(size))
    }
}
