import CGtk
import Foundation

/// What the song is about, in a dialog over the player (`SongAbout`), as the phone's About This Song: a few
/// sentences written ahead of time, background quoted from the song's Genius and Wikipedia pages, and Genius's
/// notes on its lines, each saying where it came from. From the player's title or its menu.
@MainActor
enum SongAboutPage {
    static func present(_ app: AppState, song: Song) {
        let loader = Loader()
        Dialogs.sheet("About This Song", content: loader.bin, width: 560, height: 680)
        loader.run({ () -> SonicService.AboutAnswer? in
            await app.sonic.about(song)
        }) { answer in
            switch answer {
            case .unreachable:
                return Loader.offline()
            case .unknown:
                return StatusPage(icon: "dialog-question-symbolic", title: "The server doesn't know this song",
                                  description: "Songs on this computer alone have no background yet.")
            case .about(let about) where about.isEmpty:
                return about.unavailable
                    ? StatusPage(icon: "network-offline-symbolic", title: "Couldn't reach Genius or Wikipedia",
                                 description: "The server tries again within the hour.")
                    : StatusPage(icon: "system-search-symbolic", title: "Nothing written about this song yet",
                                 description: "Neither Genius nor Wikipedia has a page for it.")
            case .about(let about):
                return ScrolledWindow(Clamp(page(song, about), maximum: 600)).vexpand()
            }
        }
    }

    private static func page(_ song: Song, _ about: SongAbout) -> Widget {
        let box = Box.vertical(spacing: 22).margin(18)
        let byline = [song.artist, song.album].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        box.append(Box.vertical(spacing: 4) {
            Label(song.title, "title-2").wrap().selectable()
            if !byline.isEmpty { Label(byline, "dim").wrap() }
            if let facts = about.facts { Label(facts, "caption", "dim").wrap() }
        })

        if let summary = about.summary {
            box.append(summaryCard("What it's about", summary.text,
                                   credit: summary.isReadingOfLyrics
                                       ? "Claude's reading of the lyrics: nothing has been written about this song."
                                       : "Written by Claude from the sources below."))
        }

        if let background = background(about.sections) {
            box.append(background)
        }

        if !about.notes.isEmpty {
            let notes = Box.vertical(spacing: 14)
            notes.append(heading("Notes on the lyrics"))
            for note in about.notes {
                notes.append(Box.vertical(spacing: 4) {
                    Label(markup: "<i>\(Markup.escape(note.fragment))</i>").wrap().selectable()
                    Label(note.text, "dim").wrap().selectable()
                }.margins(start: 12))
            }
            notes.append(Label("From Genius, written mostly by listeners.", "caption", "dim").wrap())
            box.append(notes)
        }

        if let links = links(about.links) {
            box.append(links)
        }
        return box
    }

    // MARK: - Parts shared with album and artist pages (`RecordAboutPage`)

    /// Claude's summary in its card, saying whose words they are and what they rest on.
    static func summaryCard(_ title: String, _ text: String, credit: String) -> Widget {
        let inside = Box.vertical(spacing: 8) {
            heading(title)
            Label(text).wrap().selectable()
            Label(credit, "caption", "dim").wrap()
        }.margin(14)
        return Box.vertical { inside }.css("card")
    }

    /// The passages quoted from Genius and Wikipedia, each under where it came from; nil when there are none.
    static func background(_ quoted: [SongAbout.Section]) -> Widget? {
        guard !quoted.isEmpty else { return nil }
        let sections = Box.vertical(spacing: 16)
        sections.append(heading("Background"))
        for section in quoted {
            sections.append(Box.vertical(spacing: 4) {
                Label("\(section.source) · \(section.heading)", "caption-heading", "dim").wrap()
                Label(section.text).wrap().selectable()
            })
        }
        return sections
    }

    /// The pages themselves, as buttons that open them; wraps when a summary's own sources make many.
    static func links(_ all: [SongAbout.Link]) -> Widget? {
        let links = all.compactMap { link in link.url.map { (link.name, $0) } }
        guard !links.isEmpty else { return nil }
        let row = FlowBox(spacing: 8)
        for (name, url) in links {
            row.append(Button(name, icon: "adw-external-link-symbolic", "flat", "pill") {
                g_app_info_launch_default_for_uri(url, nil, nil)
            })
        }
        return row
    }

    static func heading(_ title: String) -> Label {
        Label(title.uppercased(), "caption-heading", "dim")
    }
}
