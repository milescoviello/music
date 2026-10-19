import CGtk
import Foundation

/// The icons the app draws with, made consistent across desktops.
///
/// libadwaita is designed around the Adwaita symbolic set. Under Plasma the Breeze theme
/// answers instead, and it lacks a dozen of the names the screens use — GTK then falls
/// back to Breeze's full-colour icons, or to none — so Adwaita is preferred wherever it is
/// installed (gtk4 pulls it in on most distributions). The few glyphs Adwaita does not
/// have either are drawn here, under names of the app's own so no theme can shadow them.
@MainActor
enum BundledIcons {
    static func install() {
        preferAdwaita()
        guard let directory = writeIcons() else { return }
        gtk_icon_theme_add_search_path(gtk_icon_theme_get_for_display(gdk_display_get_default()), directory)
    }

    private static func preferAdwaita() {
        var directories = [String(cString: g_get_user_data_dir())]
        if var system = g_get_system_data_dirs() {
            while let directory = system.pointee {
                directories.append(String(cString: directory))
                system += 1
            }
        }
        guard directories.contains(where: { FileManager.default.fileExists(atPath: "\($0)/icons/Adwaita/index.theme") })
        else { return }
        var value = GValue()
        g_value_init(&value, GType(16 << 2)) // G_TYPE_STRING
        g_value_set_string(&value, "Adwaita")
        g_object_set_property(UnsafeMutableRawPointer(gtk_settings_get_default()).assumingMemoryBound(to: GObject.self), "gtk-icon-theme-name", &value)
        g_value_unset(&value)
    }

    /// Unthemed icons in a search path directory are found by file name, so the SVGs are
    /// written straight into the cache folder, and only when they have changed.
    private static func writeIcons() -> String? {
        let directory = String(cString: g_get_user_cache_dir()) + "/\(Desktop.applicationID)/icons"
        do {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            for (name, path) in icons {
                let file = "\(directory)/\(name).svg"
                let svg = """
                <svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16">\
                <path fill="#222222" fill-rule="evenodd" d="\(path)"/></svg>
                """
                if (try? String(contentsOfFile: file, encoding: .utf8)) != svg {
                    try svg.write(toFile: file, atomically: true, encoding: .utf8)
                }
            }
            return directory
        } catch {
            return nil
        }
    }

    private static let icons: [String: String] = [
        // The phone's heart.fill: favourites.
        "music-heart-symbolic":
            "M8 14.6 2.4 9.1C.9 7.6.9 5.1 2.4 3.6 3.9 2.1 6.4 2.1 8 3.8 9.6 2.1 12.1 2.1 13.6 3.6 15.1 5.1 15.1 7.6 13.6 9.1Z",
        // Three faders, for the equalizer.
        "music-equalizer-symbolic":
            "M2.5 1h1v7H5v4H3.5v3h-1v-3H1V8h1.5ZM7.5 1h1v2H10v4H8.5v8h-1V7H6V3h1.5ZM12.5 1h1v5H15v4h-1.5v5h-1v-5H11V6h1.5Z",
        // A luggage label, for record labels.
        "music-tag-symbolic":
            "M1 2a1 1 0 0 1 1-1h5.6a1 1 0 0 1 .7.3l6.4 6.4a1 1 0 0 1 0 1.4l-5.6 5.6a1 1 0 0 1-1.4 0L1.3 8.3A1 1 0 0 1 1 7.6ZM4.5 3.2a1.3 1.3 0 1 0 0 2.6 1.3 1.3 0 1 0 0-2.6Z",
        // Bars of a waveform, for sonic analysis.
        "music-waveform-symbolic":
            "M1 6h2v4H1ZM4.5 3h2v10h-2ZM8 1h2v14H8ZM11.5 4h2v8h-2ZM14.5 6.5H16v3h-1.5Z",
    ]
}
