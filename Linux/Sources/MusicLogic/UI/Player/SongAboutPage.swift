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
            let inside = Box.vertical(spacing: 8) {
                heading("What it's about")
                Label(summary.text).wrap().selectable()
                Label(summary.isReadingOfLyrics
                      ? "Claude's reading of the lyrics: nothing has been written about this song."
                      : "Written by Claude from the sources below.", "caption", "dim").wrap()
            }.margin(14)
            box.append(Box.vertical { inside }.css("card"))
        }

        if !about.sections.isEmpty {
            let sections = Box.vertical(spacing: 16)
            sections.append(heading("Background"))
            for section in about.sections {
                sections.append(Box.vertical(spacing: 4) {
                    Label("\(section.source) · \(section.heading)", "caption-heading", "dim").wrap()
                    Label(section.text).wrap().selectable()
                })
            }
            box.append(sections)
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

        let links = about.links.compactMap { link in link.url.map { (link.name, $0) } }
        if !links.isEmpty {
            let row = Box.horizontal(spacing: 8)
            for (name, url) in links {
                row.append(Button(name, icon: "adw-external-link-symbolic", "flat", "pill") {
                    g_app_info_launch_default_for_uri(url, nil, nil)
                })
            }
            box.append(row)
        }
        return box
    }

    private static func heading(_ title: String) -> Label {
        Label(title.uppercased(), "caption-heading", "dim")
    }
}
