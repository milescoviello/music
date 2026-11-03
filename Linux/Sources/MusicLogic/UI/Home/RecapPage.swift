import CGtk
import Foundation

/// The year in music, as one long page: what the play log says about this year.
@MainActor
enum RecapPage {
    static func make(_ env: Env) -> NavigationPage {
        let app = env.app
        let recap = app.history.recap()
        let body = Box.vertical(spacing: 24).margin(horizontal: 12, vertical: 24)
        let year = String(recap.year)

        guard !recap.isEmpty else {
            body.append(StatusPage(icon: "audio-x-generic-symbolic", title: "Nothing Yet", description: "Nothing has been played this year.", child: nil))
            return Page.make("Your \(year)", content: body)
        }

        let intro = Box.vertical(spacing: 6) {
            Label("Your \(year) in music", "title-1").xalign(0.5)
            Label(recap.minutes.formatted(), "recap-big", "accent", "numeric").xalign(0.5)
            Label("minutes listened", "title-4", "dim").xalign(0.5)
            Label("\(recap.plays.formatted()) plays · \(recap.songCount.formatted()) songs · \(recap.artistCount.formatted()) artists", "dim").xalign(0.5)
        }
        if let since = recap.since {
            intro.append(Label("Counted since \(since.formatted(.dateTime.month(.wide).day())), when the play log began.", "caption", "dim").xalign(0.5))
        }
        body.append(intro)

        if let top = recap.topSongs.first {
            let artwork = ArtworkView(app, size: .full, side: 220, shape: .card)
            artwork.show(top.coverArt, fallback: top.name)
            let number1 = Box.vertical(spacing: 8) {
                Label("Your number one", "title-3").xalign(0.5)
                artwork.root.halign(GTK_ALIGN_CENTER)
                Label(top.name, "title-2").xalign(0.5).wrap()
                Label(top.detail ?? "", "dim").xalign(0.5)
                Label("\(top.plays) plays · \(top.minutes) minutes", "accent").xalign(0.5)
            }
            number1.keep(artwork)
            body.append(number1)
        }

        let lists: [(title: String, entries: [Recap.Entry], art: Bool, detail: (Recap.Entry) -> String)] = [
            ("Top Songs", recap.topSongs, true, { "\($0.plays) plays" }),
            ("Top Artists", recap.topArtists, false, { "\($0.minutes) minutes" }),
            ("Top Albums", recap.topAlbums, true, { "\($0.plays) plays" }),
        ]
        for (title, entries, art, detail) in lists where !entries.isEmpty {
            let group = PreferencesGroup(title)
            for (place, entry) in entries.enumerated() {
                let row = ActionRow(entry.name, subtitle: [entry.detail, detail(entry)].compactMap { $0 }.joined(separator: " · "))
                row.prefix(Label("\(place + 1)", "song-number"))
                if art {
                    let artwork = ArtworkView(app, size: .thumb, side: 40, shape: .thumb)
                    artwork.show(entry.coverArt, fallback: entry.name)
                    row.prefix(artwork.root)
                    row.keep(artwork)
                }
                group.add(row)
            }
            body.append(group)
        }

        let habits = PreferencesGroup("How You Listened")
        func fact(_ title: String, _ value: String) {
            habits.add(ActionRow(title).suffix(Label(value, "accent")))
        }
        if let day = recap.biggestDay {
            fact("Biggest day", "\(day.minutes) minutes, \(day.date.formatted(.dateTime.weekday(.wide).month(.wide).day()))")
        }
        fact("Longest streak", "\(recap.longestStreak) days in a row")
        if let hour = recap.favouriteHour { fact("Favourite hour", Recap.hourName(hour)) }
        if let genre = recap.topGenres.first { fact("Top genre", genre.name) }
        body.append(habits)

        if recap.months.count > 1 {
            let months = PreferencesGroup("Month by Month")
            for month in recap.months {
                months.add(ActionRow(Calendar.current.monthSymbols[month.month - 1], subtitle: month.artist)
                    .suffix(Label("\(month.minutes) min", "dim")))
            }
            body.append(months)
        }

        body.append(PreferencesGroup {
            ButtonRow("Play Your Top Songs", icon: "media-playback-start-symbolic", suggested: true) {
                Task { @MainActor in
                    if !(await app.playRecap(recap)) { env.toast("Couldn't reach the server for those songs") }
                }
            }
        })
        return Page.make("Your \(year)", content: body)
    }
}
