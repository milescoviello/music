import SwiftUI

/// The year in music, a card at a time: what the play log says about this year.
struct RecapView: View {
    @Environment(AppState.self) private var appState
    @Environment(ListeningHistory.self) private var history
    @Environment(\.dismiss) private var dismiss

    @State private var isStarting = false

    var body: some View {
        let recap = history.recap()
        NavigationStack {
            Group {
                if recap.isEmpty {
                    ContentUnavailableView("Nothing Yet", systemImage: "music.note", description: Text("Nothing has been played this year."))
                } else {
                    TabView {
                        intro(recap)
                        if let top = recap.topSongs.first { number1(top) }
                        list("Top Songs", recap.topSongs.prefix(5), detail: { "\($0.plays) plays" }, art: true)
                        list("Top Artists", recap.topArtists.prefix(5), detail: { "\($0.minutes) minutes" }, art: false)
                        list("Top Albums", recap.topAlbums.prefix(5), detail: { "\($0.plays) plays" }, art: true)
                        habits(recap)
                        if recap.months.count > 1 { months(recap) }
                        finale(recap)
                    }
                    .tabViewStyle(.page(indexDisplayMode: .always))
                    .indexViewStyle(.page(backgroundDisplayMode: .always))
                }
            }
            .background(LinearGradient(colors: [Color.appTint.opacity(0.55), .black], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
            .navigationTitle("Your \(String(recap.year))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 18) { content() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(28)
            .padding(.bottom, 36)
    }

    private func big(_ text: String) -> some View {
        Text(text).font(.system(size: 64, weight: .heavy, design: .rounded)).minimumScaleFactor(0.5).lineLimit(1)
    }

    private func intro(_ recap: Recap) -> some View {
        card {
            Text("Your \(String(recap.year)) in music").font(.title.weight(.bold))
            big(recap.minutes.formatted())
            Text("minutes listened").font(.title3).foregroundStyle(.secondary)
            Text("\(recap.plays.formatted()) plays · \(recap.songCount.formatted()) songs · \(recap.artistCount.formatted()) artists")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let since = recap.since {
                Text("Counted since \(since.formatted(.dateTime.month(.wide).day())), when the app's play log began.")
                    .font(.footnote).foregroundStyle(.tertiary).multilineTextAlignment(.center)
            }
        }
    }

    private func number1(_ top: Recap.Entry) -> some View {
        card {
            Text("Your number one").font(.title2.weight(.bold))
            ArtworkImage(id: top.coverArt, size: .full, fallbackText: top.name)
                .frame(width: 240, height: 240)
            Text(top.name).font(.title.weight(.bold)).multilineTextAlignment(.center)
            if let artist = top.detail { Text(artist).font(.title3).foregroundStyle(.secondary) }
            Text("\(top.plays) plays · \(top.minutes) minutes").font(.headline).foregroundStyle(Color.appTint)
        }
    }

    private func list(_ title: String, _ entries: ArraySlice<Recap.Entry>, detail: @escaping (Recap.Entry) -> String, art: Bool) -> some View {
        card {
            Text(title).font(.title.weight(.bold))
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { place, entry in
                    HStack(spacing: 14) {
                        Text("\(place + 1)").font(.title2.weight(.heavy)).foregroundStyle(Color.appTint).frame(width: 28)
                        if art {
                            ArtworkImage(id: entry.coverArt, size: .thumb, fallbackText: entry.name).frame(width: 52, height: 52)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.name).font(.headline).lineLimit(1)
                            Text([entry.detail, detail(entry)].compactMap { $0 }.joined(separator: " · "))
                                .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private func habits(_ recap: Recap) -> some View {
        card {
            Text("How you listened").font(.title.weight(.bold))
            VStack(spacing: 22) {
                if let day = recap.biggestDay {
                    fact("\(day.minutes) minutes", "on \(day.date.formatted(.dateTime.weekday(.wide).month(.wide).day())), your biggest day")
                }
                fact("\(recap.longestStreak) days", "in a row, your longest streak")
                if let hour = recap.favouriteHour { fact(Recap.hourName(hour), "your favourite hour") }
                if let genre = recap.topGenres.first { fact(genre.name, "your top genre") }
            }
        }
    }

    private func fact(_ value: String, _ caption: String) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.system(size: 34, weight: .heavy, design: .rounded)).foregroundStyle(Color.appTint)
            Text(caption).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }

    private func months(_ recap: Recap) -> some View {
        card {
            Text("Month by month").font(.title.weight(.bold))
            VStack(alignment: .leading, spacing: 12) {
                ForEach(recap.months, id: \.month) { month in
                    HStack {
                        Text(Calendar.current.monthSymbols[month.month - 1]).font(.headline).frame(width: 110, alignment: .leading)
                        Text(month.artist).font(.body).lineLimit(1)
                        Spacer()
                        Text("\(month.minutes) min").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func finale(_ recap: Recap) -> some View {
        card {
            Text("That was your \(String(recap.year))").font(.title.weight(.bold)).multilineTextAlignment(.center)
            Button {
                isStarting = true
                Task {
                    if await appState.playRecap(recap) { dismiss() }
                    isStarting = false
                }
            } label: {
                Label(isStarting ? "Starting…" : "Play Your Top Songs", systemImage: "play.fill")
                    .font(.headline).padding(.horizontal, 20).padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.appTint)
            .disabled(isStarting)
        }
    }
}
