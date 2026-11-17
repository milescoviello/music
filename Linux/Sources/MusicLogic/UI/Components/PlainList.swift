import CGtk
import Foundation

/// The phone's plain list (`.listStyle(.plain)`): rows straight on the page, each a cover,
/// a title over a quieter line or two, and a chevron when it opens something, with the
/// separator starting where the text starts, as iOS draws it. Playlists, Downloads and
/// Search results are lists of these.
@MainActor
enum PlainList {
    /// A list to hold the rows.
    static func list() -> ListBox {
        ListBox(boxed: false).css("plain-list")
    }

    /// One row. `detail` is a third, fainter line (Downloads' size and length). iOS 26's
    /// plain rows are their cover plus about 38 points: 94 with a 56-point cover, 70 with
    /// a 40-point one.
    static func row(
        leading: Widget?,
        title: String,
        subtitle: String? = nil,
        detail: String? = nil,
        trailing: Widget? = nil,
        chevron: Bool = true,
        minHeight: Int32 = 64,
        titleClasses: [String] = []
    ) -> Box {
        let titleLabel = Label(title, "plain-title").xalign(0).ellipsize()
        for name in titleClasses { titleLabel.css(name) }
        let text = Box.vertical(spacing: 2) {
            titleLabel
            if let subtitle, !subtitle.isEmpty { Label(subtitle, "plain-subtitle").xalign(0).ellipsize() }
            if let detail, !detail.isEmpty { Label(detail, "plain-detail").xalign(0).ellipsize() }
        }.valign(GTK_ALIGN_CENTER).hexpand()
        let body = Box.horizontal(spacing: 12) {
            text
            if let trailing { trailing.valign(GTK_ALIGN_CENTER) }
            if chevron { Icon(Symbol.icon("chevron.right"), size: 14).css("row-chevron").valign(GTK_ALIGN_CENTER) }
        }.css("plain-row-body")
        body.size(width: -1, height: minHeight)
        let row = Box.horizontal(spacing: 12) {
            if let leading { leading.valign(GTK_ALIGN_CENTER) }
            body.hexpand()
        }.css("plain-row")
        return row
    }

    /// A section's header over a plain list: "Pinned", "Playlists".
    static func header(_ title: String) -> Label {
        Label(title, "list-section-header").xalign(0)
    }

    /// The small print under a list.
    static func footer(_ text: String) -> Label {
        Label(text, "list-footer").xalign(0).lines(3)
    }
}
