import CGtk
import Foundation

/// The About section of an album or artist page, as the phone's `RecordAboutSection` (`SongAbout` from the
/// companion service, `record_about.py`): Claude's summary, else the first passage of its Genius or Wikipedia page,
/// saying whose words they are. "Sources" opens a dialog with everything it rests on, quoted, and the pages' links.
@MainActor
enum RecordAboutPage {
    /// Nil when there is nothing to say: then the page shows the server agents' review or biography, if any.
    static func group(_ about: SongAbout, kind: RecordKind, title: String, byline: String? = nil) -> Widget? {
        guard let preview = about.preview(of: kind) else { return nil }
        let group = PreferencesGroup(kind == .album ? "About This Album" : "About") {
            Box.vertical(spacing: 8) {
                Label(preview.text, "dim").wrap().selectable()
                Label(preview.credit, "caption", "dim").wrap()
            }.margin(12)
        }
        if about.hasSources {
            group.suffix(Button("Sources", "flat") { present(about, kind: kind, title: title, byline: byline) })
        }
        return group
    }

    static func present(_ about: SongAbout, kind: RecordKind, title: String, byline: String?) {
        let box = Box.vertical(spacing: 22).margin(18)
        box.append(Box.vertical(spacing: 4) {
            Label(title, "title-2").wrap().selectable()
            if let byline, !byline.isEmpty { Label(byline, "dim").wrap() }
            if kind == .album, let released = about.releasedLine { Label(released, "caption", "dim").wrap() }
        })
        if let summary = about.summary, let preview = about.preview(of: kind) {
            box.append(SongAboutPage.summaryCard(kind == .album ? "What it's about" : "Who they are",
                                                 summary.text, credit: preview.credit))
        }
        if let background = SongAboutPage.background(about.sections) { box.append(background) }
        if let links = SongAboutPage.links(about.links) { box.append(links) }
        Dialogs.sheet(kind == .album ? "About This Album" : "About This Artist",
                      content: ScrolledWindow(Clamp(box, maximum: 600)).vexpand(), width: 560, height: 680)
    }
}
