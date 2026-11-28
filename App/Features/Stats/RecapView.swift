import SwiftUI

/// The year in music as a story, the way Wrapped tells it: one bold page at a time, each
/// moving on by itself, a tap on the right going forward and on the left going back. Built
/// from the play log (`Recap`), which is the server's own log of every play from any player
/// with what was imported or recorded on the devices.
struct RecapView: View {
    @Environment(AppState.self) private var appState
    @Environment(ListeningHistory.self) private var history
    @Environment(\.dismiss) private var dismiss

    @State private var recap: Recap?
    @State private var page = 0
    @State private var progress: CGFloat = 0
    @State private var shownMinutes = 0
    @State private var isStarting = false

    private enum Page: Hashable {
        case intro, minutes, genre, topArtist, artists, topSong, songs, albums, habits, months, summary, finale
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let recap {
                if recap.isEmpty {
                    empty
                } else {
                    story(recap)
                }
            } else {
                ProgressView().tint(.white)
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .task {
            await history.loaded()
            recap = history.recap()
        }
    }

    // MARK: - The story

    private func pages(_ recap: Recap) -> [Page] {
        var pages: [Page] = [.intro, .minutes]
        if !recap.topGenres.isEmpty { pages.append(.genre) }
        if !recap.topArtists.isEmpty { pages.append(.topArtist) }
        if recap.topArtists.count > 1 { pages.append(.artists) }
        if !recap.topSongs.isEmpty { pages.append(.topSong) }
        if recap.topSongs.count > 1 { pages.append(.songs) }
        if !recap.topAlbums.isEmpty { pages.append(.albums) }
        pages.append(.habits)
        if recap.months.count > 1 { pages.append(.months) }
        pages.append(contentsOf: [.summary, .finale])
        return pages
    }

    /// How long a page stays before it moves on; nil for the ones that wait for a tap.
    private func duration(_ page: Page) -> Double? {
        switch page {
        case .intro: return 4
        case .artists, .songs, .albums, .months: return 8
        case .summary, .finale: return nil
        default: return 6.5
        }
    }

    private func story(_ recap: Recap) -> some View {
        let all = pages(recap)
        let current = all[min(page, all.count - 1)]
        return GeometryReader { geometry in
            ZStack(alignment: .top) {
                backdrop(current)
                    .ignoresSafeArea()
                    .animation(.easeInOut(duration: 0.6), value: current)

                content(current, recap)
                    .id(current)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.92)),
                                            removal: .opacity))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 28)
                    .padding(.top, 70)
                    .padding(.bottom, 40)

                VStack(spacing: 14) {
                    bars(count: all.count)
                    HStack {
                        Text("Your \(String(recap.year)) Wrapped")
                            .font(.footnote.weight(.semibold))
                            .opacity(0.8)
                        Spacer()
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.headline.weight(.bold))
                                .padding(10)
                                .background(.black.opacity(0.25), in: Circle())
                        }
                        .accessibilityLabel("Close")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .foregroundStyle(.white)
            .contentShape(Rectangle())
            .onTapGesture { location in
                if location.x < geometry.size.width / 3 { go(-1, of: all.count) } else { go(1, of: all.count) }
            }
            .gesture(DragGesture(minimumDistance: 40).onEnded { drag in
                if drag.translation.height > 120 { dismiss() }
                else if drag.translation.width < -60 { go(1, of: all.count) }
                else if drag.translation.width > 60 { go(-1, of: all.count) }
            })
        }
        .task(id: page) {
            progress = 0
            guard let seconds = duration(current) else { return }
            withAnimation(.linear(duration: seconds)) { progress = 1 }
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            go(1, of: all.count)
        }
    }

    private func go(_ step: Int, of count: Int) {
        let next = page + step
        guard next >= 0, next < count else { return }
        withAnimation(.spring(duration: 0.45)) { page = next }
    }

    private func bars(count: Int) -> some View {
        HStack(spacing: 4) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(.white.opacity(0.3))
                    .overlay(alignment: .leading) {
                        GeometryReader { bar in
                            Capsule()
                                .fill(.white)
                                .frame(width: bar.size.width * filled(index))
                        }
                    }
                    .frame(height: 3)
            }
        }
    }

    private func filled(_ index: Int) -> CGFloat {
        index < page ? 1 : index == page ? progress : 0
    }

    // MARK: - Pages

    @ViewBuilder
    private func content(_ current: Page, _ recap: Recap) -> some View {
        switch current {
        case .intro: intro(recap)
        case .minutes: minutes(recap)
        case .genre: genre(recap)
        case .topArtist: topArtist(recap)
        case .artists: ranked("Your top artists", recap.topArtists.prefix(5), detail: { "\($0.minutes.formatted()) minutes" }, round: true)
        case .topSong: topSong(recap)
        case .songs: ranked("Your top songs", recap.topSongs.prefix(5), detail: { "\($0.plays.formatted()) plays" }, round: false)
        case .albums: ranked("Your top albums", recap.topAlbums.prefix(5), detail: { "\($0.plays.formatted()) plays" }, round: false)
        case .habits: habits(recap)
        case .months: months(recap)
        case .summary: summary(recap)
        case .finale: finale(recap)
        }
    }

    private func intro(_ recap: Recap) -> some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "sparkles")
                .font(.system(size: 64, weight: .bold))
            Text("Your \(String(recap.year))\nWrapped")
                .font(.system(size: 54, weight: .black, design: .rounded))
                .multilineTextAlignment(.center)
            Text("Everything you played this year, from every player")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .opacity(0.85)
            Spacer()
            Text("Tap to start")
                .font(.footnote.weight(.semibold))
                .opacity(0.7)
        }
    }

    private func minutes(_ recap: Recap) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Text("This year you listened for")
                .font(.title2.weight(.bold))
            Text(shownMinutes.formatted())
                .font(.system(size: 80, weight: .black, design: .rounded).monospacedDigit())
                .contentTransition(.numericText(value: Double(shownMinutes)))
                .minimumScaleFactor(0.4)
                .lineLimit(1)
            Text("minutes")
                .font(.system(size: 34, weight: .heavy, design: .rounded))
            Text("That's \(days(recap.minutes)) days of music, about \(perDay(recap).formatted()) minutes every day.")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .opacity(0.9)
            if let since = recap.since, Calendar.current.component(.dayOfYear, from: since) > 7 {
                Text("Counted since \(since.formatted(.dateTime.month(.wide).day())), where your play log begins.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .opacity(0.7)
            }
            Spacer()
        }
        .onAppear {
            shownMinutes = 0
            withAnimation(.easeOut(duration: 2.4)) { shownMinutes = recap.minutes }
        }
    }

    private func genre(_ recap: Recap) -> some View {
        VStack(spacing: 22) {
            Spacer()
            Text("Your top genre")
                .font(.title2.weight(.bold))
            if let top = recap.topGenres.first {
                Text(top.name)
                    .font(.system(size: 60, weight: .black, design: .rounded))
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.4)
                Text("\(top.minutes.formatted()) minutes")
                    .font(.title3.weight(.semibold))
                    .opacity(0.85)
            }
            VStack(spacing: 10) {
                ForEach(Array(recap.topGenres.dropFirst().prefix(4).enumerated()), id: \.element.id) { place, entry in
                    HStack {
                        Text("\(place + 2)").font(.title3.weight(.heavy)).frame(width: 30)
                        Text(entry.name).font(.title3.weight(.semibold)).lineLimit(1)
                        Spacer()
                    }
                }
            }
            .padding(.top, 8)
            Spacer()
        }
    }

    private func topArtist(_ recap: Recap) -> some View {
        VStack(spacing: 18) {
            Spacer()
            Text("Your top artist")
                .font(.title2.weight(.bold))
            if let top = recap.topArtists.first {
                ArtworkImage(id: top.coverArt, size: .full, cornerRadius: 140, fallbackText: top.name)
                    .frame(width: 260, height: 260)
                    .shadow(radius: 24)
                Text(top.name)
                    .font(.system(size: 44, weight: .black, design: .rounded))
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.4)
                    .lineLimit(2)
                Text("\(top.minutes.formatted()) minutes, \(top.plays.formatted()) plays")
                    .font(.title3.weight(.semibold))
                    .opacity(0.9)
            }
            Spacer()
        }
    }

    private func topSong(_ recap: Recap) -> some View {
        VStack(spacing: 18) {
            Spacer()
            Text("Your song of the year")
                .font(.title2.weight(.bold))
            if let top = recap.topSongs.first {
                ArtworkImage(id: top.coverArt, size: .full, cornerRadius: 12, fallbackText: top.name)
                    .frame(width: 270, height: 270)
                    .shadow(radius: 24)
                Text(top.name)
                    .font(.system(size: 38, weight: .black, design: .rounded))
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.4)
                    .lineLimit(2)
                if let artist = top.detail {
                    Text(artist).font(.title3.weight(.semibold)).opacity(0.85)
                }
                Text("You played it \(top.plays.formatted()) times")
                    .font(.headline)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(.white.opacity(0.18), in: Capsule())
            }
            Spacer()
        }
    }

    private func ranked(_ title: String, _ entries: ArraySlice<Recap.Entry>, detail: @escaping (Recap.Entry) -> String,
                        round: Bool) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer()
            Text(title)
                .font(.system(size: 40, weight: .black, design: .rounded))
                .padding(.bottom, 6)
            ForEach(Array(entries.enumerated()), id: \.element.id) { place, entry in
                HStack(spacing: 14) {
                    Text("\(place + 1)")
                        .font(.system(size: 30, weight: .black, design: .rounded))
                        .frame(width: 34)
                    ArtworkImage(id: entry.coverArt, size: .thumb, cornerRadius: round ? 30 : 6, fallbackText: entry.name)
                        .frame(width: 60, height: 60)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.name).font(.headline.weight(.bold)).lineLimit(1)
                        Text([entry.detail, detail(entry)].compactMap { $0 }.joined(separator: " · "))
                            .font(.subheadline)
                            .opacity(0.8)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            }
            Spacer()
        }
    }

    private func habits(_ recap: Recap) -> some View {
        let who = personality(recap)
        return VStack(spacing: 22) {
            Spacer()
            Text("Your listening personality")
                .font(.title2.weight(.bold))
            Text(who.title)
                .font(.system(size: 46, weight: .black, design: .rounded))
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.4)
            Text(who.line)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .opacity(0.9)
            VStack(spacing: 16) {
                if let day = recap.biggestDay {
                    fact("\(day.minutes.formatted()) minutes", "on \(day.date.formatted(.dateTime.weekday(.wide).month(.wide).day())), your biggest day")
                }
                fact("\(recap.longestStreak) days", "in a row, your longest streak")
                if let hour = recap.favouriteHour { fact(Recap.hourName(hour), "your favourite hour") }
            }
            .padding(.top, 6)
            Spacer()
        }
    }

    private func fact(_ value: String, _ caption: String) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.system(size: 30, weight: .heavy, design: .rounded))
            Text(caption).font(.subheadline).opacity(0.8).multilineTextAlignment(.center)
        }
    }

    private func months(_ recap: Recap) -> some View {
        let peak = max(recap.months.map(\.minutes).max() ?? 1, 1)
        return VStack(alignment: .leading, spacing: 12) {
            Spacer()
            Text("Month by month")
                .font(.system(size: 40, weight: .black, design: .rounded))
                .padding(.bottom, 4)
            ForEach(recap.months, id: \.month) { month in
                HStack(spacing: 10) {
                    Text(Calendar.current.shortMonthSymbols[month.month - 1])
                        .font(.headline.weight(.bold))
                        .frame(width: 42, alignment: .leading)
                    GeometryReader { bar in
                        Capsule()
                            .fill(.white.opacity(0.85))
                            .frame(width: max(6, bar.size.width * CGFloat(month.minutes) / CGFloat(peak)))
                    }
                    .frame(height: 10)
                    Text(month.artist)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .frame(width: 130, alignment: .trailing)
                }
            }
            Spacer()
        }
    }

    private func summary(_ recap: Recap) -> some View {
        VStack(spacing: 20) {
            Spacer()
            summaryCard(recap)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(radius: 20)
            if let image = shareImage(recap) {
                ShareLink(item: image, preview: SharePreview("My \(String(recap.year)) Wrapped", image: image)) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .font(.headline)
                        .padding(.horizontal, 22).padding(.vertical, 12)
                        .background(.white, in: Capsule())
                        .foregroundStyle(.black)
                }
            }
            Spacer()
        }
    }

    /// The card that is shared: text only, because artwork loads after the picture is taken.
    private func summaryCard(_ recap: Recap) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("My \(String(recap.year)) Wrapped")
                .font(.system(size: 28, weight: .black, design: .rounded))
            HStack(alignment: .top, spacing: 18) {
                column("Top artists", recap.topArtists.prefix(5).map(\.name))
                column("Top songs", recap.topSongs.prefix(5).map(\.name))
            }
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Minutes listened").font(.caption.weight(.semibold)).opacity(0.8)
                    Text(recap.minutes.formatted()).font(.system(size: 30, weight: .black, design: .rounded))
                }
                if let genre = recap.topGenres.first {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Top genre").font(.caption.weight(.semibold)).opacity(0.8)
                        Text(genre.name).font(.system(size: 24, weight: .black, design: .rounded)).lineLimit(1)
                    }
                }
            }
        }
        .foregroundStyle(.white)
        .padding(24)
        .frame(width: 340, alignment: .leading)
        .background(LinearGradient(colors: [Color(red: 0.55, green: 0.14, blue: 0.86), Color.appTint],
                                   startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    private func column(_ title: String, _ names: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).opacity(0.8)
            ForEach(Array(names.enumerated()), id: \.offset) { place, name in
                Text("\(place + 1) \(name)").font(.subheadline.weight(.bold)).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @MainActor
    private func shareImage(_ recap: Recap) -> Image? {
        let renderer = ImageRenderer(content: summaryCard(recap))
        renderer.scale = 3
        return renderer.uiImage.map { Image(uiImage: $0) }
    }

    private func finale(_ recap: Recap) -> some View {
        VStack(spacing: 22) {
            Spacer()
            Text("That was your \(String(recap.year))")
                .font(.system(size: 44, weight: .black, design: .rounded))
                .multilineTextAlignment(.center)
            Text("\(recap.plays.formatted()) plays, \(recap.songCount.formatted()) songs, \(recap.artistCount.formatted()) artists")
                .font(.title3.weight(.semibold))
                .opacity(0.9)
            Button {
                isStarting = true
                Task {
                    if await appState.playRecap(recap) { dismiss() }
                    isStarting = false
                }
            } label: {
                Label(isStarting ? "Starting…" : "Play your top songs", systemImage: "play.fill")
                    .font(.headline)
                    .padding(.horizontal, 24).padding(.vertical, 14)
                    .background(.white, in: Capsule())
                    .foregroundStyle(.black)
            }
            .disabled(isStarting)
            Spacer()
        }
    }

    private var empty: some View {
        VStack(spacing: 16) {
            ContentUnavailableView("Nothing Yet", systemImage: "music.note",
                                   description: Text("Nothing has been played this year."))
            Button("Close") { dismiss() }
        }
    }

    // MARK: - Working out

    private func backdrop(_ page: Page) -> LinearGradient {
        let colours: [Color]
        switch page {
        case .intro: colours = [Color.appTint, Color(red: 0.07, green: 0.07, blue: 0.2)]
        case .minutes: colours = [Color(red: 0.12, green: 0.84, blue: 0.38), Color(red: 0.02, green: 0.25, blue: 0.2)]
        case .genre: colours = [Color(red: 0.98, green: 0.45, blue: 0.1), Color(red: 0.55, green: 0.05, blue: 0.3)]
        case .topArtist, .artists: colours = [Color(red: 0.2, green: 0.3, blue: 0.95), Color(red: 0.05, green: 0.02, blue: 0.3)]
        case .topSong, .songs: colours = [Color(red: 0.93, green: 0.18, blue: 0.5), Color(red: 0.25, green: 0.02, blue: 0.25)]
        case .albums: colours = [Color(red: 0.95, green: 0.75, blue: 0.1), Color(red: 0.6, green: 0.2, blue: 0.05)]
        case .habits: colours = [Color(red: 0.5, green: 0.2, blue: 0.95), Color(red: 0.08, green: 0.05, blue: 0.25)]
        case .months: colours = [Color(red: 0.1, green: 0.7, blue: 0.85), Color(red: 0.03, green: 0.15, blue: 0.3)]
        case .summary, .finale: colours = [Color.appTint, Color.black]
        }
        return LinearGradient(colors: colours, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private func days(_ minutes: Int) -> String {
        (Double(minutes) / 1_440).formatted(.number.precision(.fractionLength(1)))
    }

    /// Minutes a day over the part of the year the log covers, up to today.
    private func perDay(_ recap: Recap) -> Int {
        let calendar = Calendar.current
        let yearStart = calendar.date(from: DateComponents(year: recap.year, month: 1, day: 1)) ?? .now
        let yearEnd = calendar.date(from: DateComponents(year: recap.year + 1, month: 1, day: 1)) ?? .now
        let start = max(yearStart, recap.since.map { calendar.startOfDay(for: $0) } ?? yearStart)
        let end = min(Date.now, yearEnd)
        let days = max(1, (calendar.dateComponents([.day], from: start, to: end).day ?? 0) + 1)
        return recap.minutes / days
    }

    /// When the music mostly plays, and how widely it ranges.
    private func personality(_ recap: Recap) -> (title: String, line: String) {
        let hour = recap.favouriteHour ?? 20
        let time: String
        switch hour {
        case 5..<12: time = "Early Bird"
        case 12..<18: time = "Daytime"
        case 18..<23: time = "Evening"
        default: time = "Night Owl"
        }
        let variety = recap.plays > 0 ? Double(recap.songCount) / Double(recap.plays) : 0
        let kind: String
        let line: String
        if variety > 0.45 {
            kind = "Explorer"
            line = "\(recap.songCount.formatted()) different songs: you were always after something new."
        } else if variety > 0.2 {
            kind = "Collector"
            line = "\(recap.songCount.formatted()) songs, with favourites you kept coming back to."
        } else {
            kind = "Loyalist"
            line = "You found what you love and played it again and again."
        }
        return ("The \(time) \(kind)", line)
    }
}
