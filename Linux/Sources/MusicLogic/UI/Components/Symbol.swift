import CGtk
import Foundation

/// The phone's icons, asked for by the phone's own SF Symbol names, so a screen ported from
/// SwiftUI keeps its `systemImage:` strings and the shared code's symbols (stations,
/// Autoplay) need no Linux names of their own. SF Symbols may only be drawn on Apple's
/// platforms, so each is drawn with the Phosphor icon (MIT) nearest to it
/// (`SymbolTable`, written by `tools/symbols.py`); a `.fill` name takes Phosphor's filled
/// weight.
@MainActor
enum Symbol {
    /// The icon name to give GTK: `house` → `ph-house-symbolic`, `heart.fill` →
    /// `ph-heart-fill-symbolic`. A name with no twin draws a question mark, not nothing.
    static func icon(_ sf: String) -> String {
        var base = sf
        var fill = false
        if base.hasSuffix(".fill") {
            base.removeLast(5)
            fill = true
        }
        guard let name = SymbolTable.phosphor[base] else { return "ph-question-symbolic" }
        return "ph-\(name)\(fill ? "-fill" : "")-symbolic"
    }

    /// The icons' folder: installed beside the app's data by `install.sh`, or read from the
    /// source tree while developing, as the fonts are.
    static func install() {
        let folders = [
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/share/\(Desktop.applicationID)/symbols"),
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../Resources/symbols").standardized,
        ]
        guard let folder = folders.first(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent("ph-house-symbolic.svg").path) })
        else { return }
        gtk_icon_theme_add_search_path(gtk_icon_theme_get_for_display(gdk_display_get_default()), folder.path)
    }
}
