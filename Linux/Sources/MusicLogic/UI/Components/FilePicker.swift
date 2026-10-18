import CGtk
import Foundation

/// The desktop's own file chooser — the portal's, under Flatpak or on Plasma — for picking
/// an image: a playlist's cover.
@MainActor
enum FilePicker {
    static func image(title: String, picked: @escaping @MainActor (Data) -> Void) {
        let dialog = gtk_file_dialog_new()!
        gtk_file_dialog_set_title(dialog, title)
        let filter = gtk_file_filter_new()!
        gtk_file_filter_set_name(filter, "Images")
        gtk_file_filter_add_mime_type(filter, "image/*")
        gtk_file_dialog_set_default_filter(dialog, filter)
        g_object_unref(filter.rawPointer)

        typealias Picked = @MainActor (Data) -> Void
        let box = Unmanaged.passRetained(ClosureBox<Picked>(picked)).toOpaque()
        gtk_file_dialog_open(dialog, Desktop.window?.cast(), nil, { source, result, data in
            guard let data else { return }
            let picked = Unmanaged<ClosureBox<Picked>>.fromOpaque(data).takeRetainedValue().value
            var error: UnsafeMutablePointer<GError>?
            let file = gtk_file_dialog_open_finish(OpaquePointer(source), result, &error)
            if let error { g_error_free(error) }
            guard let file else { return }
            defer { g_object_unref(file.rawPointer) }
            var contents: UnsafeMutablePointer<CChar>?
            var length: gsize = 0
            guard g_file_load_contents(file, nil, &contents, &length, nil, nil) != 0, let contents else { return }
            let bytes = Data(bytes: contents, count: Int(length))
            g_free(contents)
            MainActor.assumeIsolated { picked(bytes) }
        }, box)
        g_object_unref(dialog.rawPointer)
    }
}
