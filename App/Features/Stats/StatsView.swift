import SwiftUI
import UniformTypeIdentifiers

/// Listening statistics, all time, and what the server holds.
///
/// Every figure is all time: there is no window to pick. The play log they come from is
/// the server's own, every play any player logged back to the first (Plex's era
/// included), which `TasteSync` brings in through sonic, with what this app and the other
/// devices recorded. Navidrome's own API adds the per-song counts and last-played dates.
struct StatsView: View {
    @Environment(AppState.self) private var appState
    @Environment(ListeningHistory.self) private var history

    @State private var figures = HistoryFigures()
    @State private var confirmsClearHistory = false
    @State private var scan: ScanStatus?
    @State private var starred: Starred2?
    @State private var mostPlayed: [Album] = []
    @State private var nowPlaying: [NowPlayingEntry] = []
    @State private var recentTracks: [NavidromeClient.Song] = []
    @State private var topTracks: [NavidromeClient.Song] = []
    @State private var isShowingRecap = false
    /// The server's own count of its play log: the all-time figures, when it can be had.
    @State private var server: SonicClient.ServerPlaysSummary?
    @State private var isPickingImport = false
    @State private var isImporting = false
    @State private var importReport: String?

    var body: some View {
        List {
            Group {
                Section {
                    Button {
                        isShowingRecap = true
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "sparkles")
                                .font(.title.weight(.bold))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Your \(String(Calendar.current.component(.year, from: .now))) Wrapped")
                                    .font(.title3.weight(.heavy))
                                Text("Your year in music, a story at a time")
                                    .font(.subheadline)
                                    .opacity(0.85)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                        }
                        .foregroundStyle(.white)
                        .padding(.vertical, 10)
                    }
                    .listRowBackground(
                        LinearGradient(colors: [Color.appTint, Color(red: 0.12, green: 0.84, blue: 0.38)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                }
                listeningSection
                shapeSection
                ChartsSections()
                genreSection
                allTimeSection
                nowPlayingSection
                librarySection
                StorageSection()
            }
            .glassRow()
        }
        .navigationTitle("Stats")
        .fullScreenCover(isPresented: $isShowingRecap) { RecapView() }
        .playerClearance()
        .refreshable { await load() }
        .task { await load() }
    }

    // MARK: - Listening

    // Two sections now, so the builder attribute is required.
    @ViewBuilder
    private var listeningSection: some View {
        Section {
            VStack(spacing: 4) {
                Text(totalMinutes.formatted())
                    .font(.system(size: 48, weight: .heavy, design: .rounded).monospacedDigit())
                    .foregroundStyle(Color.appTint)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                Text("minutes listened")
                    .font(.headline)
                Text(hoursAndDays)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)

            HStack {
                figure(totalPlays.formatted(), "plays")
                Divider()
                figure("\(log.streak)", "day streak")
                Divider()
                figure(appState.skips.count(in: .all).formatted(), "skipped")
            }
            .frame(maxWidth: .infinity)
        } header: {
            Text("Your Listening, All Time")
        } footer: {
            if let first = firstPlay {
                Text("Every play your server has logged since \(first.formatted(.dateTime.month(.wide).day().year())), from any player.")
            } else {
                Text("Nothing yet. The server's play log comes in when the app next reaches it.")
            }
        }

        Section {
            Button {
                isPickingImport = true
            } label: {
                Label(isImporting ? "Importing…" : "Import from YouTube or Apple Music", systemImage: "square.and.arrow.down")
            }
            .disabled(isImporting)
        } header: {
            Text("History From Elsewhere")
        } footer: {
            Text(importReport ?? "Google Takeout: choose YouTube and YouTube Music, with the history as JSON. Apple: privacy.apple.com, request a copy of your data, Apple Media Services. The zip as it downloads is fine, and importing one again adds nothing twice.")
        }
        .fileImporter(isPresented: $isPickingImport, allowedContentTypes: [.zip, .json, .commaSeparatedText, .data],
                      allowsMultipleSelection: true) { result in
            guard case let .success(files) = result, !files.isEmpty else { return }
            Task { await importHistory(files) }
        }

        if !history.plays.isEmpty {
            Section {
                // Export sits beside Clear on purpose: the log lives in Application
                // Support and is excluded from backups, so without a way out, clearing it
                // is unrecoverable. Offering both makes the destructive one safe to offer.
                ShareLink(item: log.csv) {
                    Label("Export History", systemImage: "square.and.arrow.up")
                }

                Button("Clear Listening History", systemImage: "trash", role: .destructive) {
                    confirmsClearHistory = true
                }
            } footer: {
                Text("\(history.plays.count) plays in your history. Clearing empties this phone's copy; the server's play counts and its play log stay as they are.")
            }
            .confirmationDialog(
                "Delete this phone's copy of \(history.plays.count) plays?",
                isPresented: $confirmsClearHistory,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    history.clear()
                    appState.taste.readServerLogAgain()
                    Task { await appState.taste.sync() }
                }
            } message: {
                Text("Every play the server logged comes back from its play log. Only plays the server never got are lost.")
            }
        }
    }

    /// Each picked file to the service, which reads it into the shared play log; then a sync, so
    /// its plays are here at once rather than at the next one. Copied out first: a file from
    /// Files or iCloud is only readable while its security scope is open.
    private func importHistory(_ files: [URL]) async {
        isImporting = true
        defer { isImporting = false }
        let client = SonicClient(configuration: appState.sonic.configuration)
        var lines: [String] = []
        for file in files {
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + file.lastPathComponent)
            defer { try? FileManager.default.removeItem(at: copy) }
            do {
                let scoped = file.startAccessingSecurityScopedResource()
                let copied = Result { try FileManager.default.copyItem(at: file, to: copy) }
                if scoped { file.stopAccessingSecurityScopedResource() }
                try copied.get()
                let result = try await client.importHistory(file: copy)
                let name = result.source == "apple" ? "Apple Music" : "YouTube"
                let years = [result.first, result.last].compactMap { $0 }
                    .map { Calendar.current.component(.year, from: Date(timeIntervalSince1970: $0)) }
                let span = years.count == 2 ? (years[0] == years[1] ? " from \(years[0])" : " from \(years[0]) to \(years[1])") : ""
                lines.append("\(name): \(result.plays.formatted()) plays\(span), \(result.matched.formatted()) in your library, \(result.added.formatted()) new.")
                await Diagnostics.shared.record(
                    "history", "imported \(file.lastPathComponent): \(result.source), \(result.plays) plays\(span), \(result.matched) in the library, \(result.added) new"
                )
            } catch {
                let said: String
                if case let SonicError.refused(message) = error { said = message } else { said = error.localizedDescription }
                lines.append("\(file.lastPathComponent): \(said)")
                await Diagnostics.shared.record("history", "import of \(file.lastPathComponent) failed: \(Diagnostics.describe(error))")
            }
        }
        importReport = lines.joined(separator: "\n")
        await appState.taste.sync()
    }

    /// The play log's figures for this redraw, worked out only when the log has changed.
    private var log: HistoryFigures.Log { figures.log(of: history) }
    private var current: HistoryFigures.Windowed { figures.windowed(.all, of: history) }

    /// The server's count when it answered, which is the whole log; the copy here otherwise. The
    /// two agree once the copy has read the log (TasteSync checks), so this is the same number
    /// either way, only sooner.
    private var totalSeconds: Int { max(server?.seconds ?? 0, current.seconds) }
    private var totalPlays: Int { max(server?.plays ?? 0, current.count) }
    private var totalMinutes: Int { totalSeconds / 60 }
    private var firstPlay: Date? {
        [server?.first.map(Date.init(timeIntervalSince1970:)), history.plays.first?.at].compactMap { $0 }.min()
    }

    private var hoursAndDays: String {
        let hours = totalSeconds / 3_600
        let days = Double(totalSeconds) / 86_400
        return "\(hours.formatted()) hours, or \(days.formatted(.number.precision(.fractionLength(1)))) days of music"
    }

    private func figure(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(Color.appTint)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Shape of listening

    private var shapeSection: some View {
        Section("When You Listen") {
            HourChart(values: current.byHour)
                .frame(height: 90)
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 4, trailing: 16))

            MonthChart(months: log.byMonth)
                .frame(height: 70)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 12, trailing: 16))
        }
    }

    // MARK: - Tops

    /// Charts has the songs, albums and artists; genres only here.
    @ViewBuilder
    private var genreSection: some View {
        rankSection("Top Genres", current.genres)
    }

    @ViewBuilder
    private func rankSection(_ title: String, _ entries: [ListeningHistory.Ranked]) -> some View {
        if !entries.isEmpty {
            Section(title) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    HStack(spacing: Metrics.itemSpacing) {
                        Text("\(index + 1)")
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .frame(width: 20, alignment: .trailing)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.name).lineLimit(1)
                            if let subtitle = entry.subtitle {
                                Text(subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }

                        Spacer(minLength: 8)

                        Text("\(entry.count)")
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(Color.appTint)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    // MARK: - All time, from the server

    @ViewBuilder
    private var allTimeSection: some View {
        if !topTracks.isEmpty {
            Section {
                ForEach(Array(topTracks.prefix(10).enumerated()), id: \.element.id) { index, song in
                    trackRow(song, rank: index + 1, trailing: "\(song.playCount ?? 0)")
                }
            } header: {
                Text("Most Played Tracks")
            } footer: {
                // No figure: the exact count cannot be had from any single call, and a
                // hardcoded one goes stale the moment anything is played.
                Text("Every device, all time — including the plays imported from Plex.")
            }
        }

        if !recentTracks.isEmpty {
            Section {
                ForEach(recentTracks.prefix(15)) { song in
                    trackRow(song, rank: nil, trailing: relative(song.playDate))
                }
            } header: {
                Text("Recently Played")
            } footer: {
                Text("Last played, from Navidrome — so a track you played on the desktop shows here too.")
            }
        }
    }

    private func trackRow(
        _ song: NavidromeClient.Song,
        rank: Int?,
        trailing: String
    ) -> some View {
        HStack(spacing: Metrics.itemSpacing) {
            if let rank {
                Text("\(rank)")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 20, alignment: .trailing)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(song.title).lineLimit(1)
                if let artist = song.artist {
                    Text(artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            Text(trailing)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func relative(_ date: Date?) -> String {
        guard let date else { return "" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: .now)
    }

    // MARK: - Elsewhere

    @ViewBuilder
    private var nowPlayingSection: some View {
        if !nowPlaying.isEmpty {
            Section {
                ForEach(nowPlaying) { entry in
                    HStack(spacing: Metrics.itemSpacing) {
                        ArtworkImage(
                            id: entry.coverArt,
                            size: .thumb,
                            cornerRadius: Metrics.radiusThumb
                        )
                        .frame(width: Metrics.thumbSmall, height: Metrics.thumbSmall)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.title ?? "Unknown").lineLimit(1)
                            Text([entry.artist, entry.playerName]
                                .compactMap { $0 }
                                .joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            } header: {
                Text("Playing Now")
            } footer: {
                Text("Anything your account is playing, on any device.")
            }
        }
    }

    // MARK: - Library and storage

    @ViewBuilder
    private var librarySection: some View {
        Section {
            if let count = scan?.count {
                LabeledContent("Tracks", value: "\(count)")
            }
            if let starred {
                LabeledContent("Favourite songs", value: "\(starred.songs.count)")
                LabeledContent("Favourite albums", value: "\(starred.albums.count)")
            }
            if let last = scan?.lastScanAt {
                LabeledContent(
                    "Last scan",
                    value: last.formatted(date: .abbreviated, time: .shortened)
                )
            }
        } header: {
            Text("Library")
        } footer: {
            Text("From the server, so this counts every play however you made it.")
        }

        if !mostPlayed.isEmpty {
            Section {
                ForEach(mostPlayed.prefix(10)) { album in
                    NavigationLink(value: Destination.album(AlbumRef(album))) {
                        HStack(spacing: Metrics.itemSpacing) {
                            ArtworkImage(
                                id: album.coverArt,
                                size: .thumb,
                                cornerRadius: Metrics.radiusThumb
                            )
                            .frame(width: Metrics.thumbSmall, height: Metrics.thumbSmall)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(album.name).lineLimit(1)
                                if let artist = album.artist {
                                    Text(artist)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                }
            } header: {
                Text("Most Played, All Time")
            } footer: {
                Text("Includes the plays imported from Plex.")
            }
        }
    }

    private func load() async {
        async let status = try? appState.client.scanStatus()
        async let stars = try? appState.client.starred()
        // Each once, with all its copies' plays: the two library folders hold most twice.
        async let frequent = try? appState.client.mostPlayedAlbums(size: 10)
        async let playing = try? appState.client.nowPlaying()
        async let recent = try? appState.native.recentlyPlayed(limit: 25)
        async let top = try? appState.native.mostPlayedRecordings(limit: 25)
        async let counted = try? SonicClient(configuration: appState.sonic.configuration)
            .serverPlaysSummary(user: appState.credentials?.username ?? "")

        scan = await status
        starred = await stars
        mostPlayed = await frequent ?? []
        nowPlaying = await playing ?? []
        recentTracks = await recent ?? []
        topTracks = await top ?? []
        if let counted = await counted { server = counted }
        let here = history.plays
        await Diagnostics.shared.record(
            "stats",
            "shown: \(totalPlays) plays, \(totalMinutes) min (server \(server.map { "\($0.plays) plays, \($0.seconds / 60) min" } ?? "unknown"); "
                + "here \(here.count) plays, \(current.seconds / 60) min, \(here.reduce(0) { $0 + ($1.duration > 0 ? 0 : 1) }) with no length)"
        )
    }
}

/// What the screen works out from the play log, kept from one redraw to the next.
///
/// Every figure walks the whole log, up to 20,000 plays, several with calendar arithmetic,
/// and the export formats a date for every play. All of it ran in the body: once for each
/// server answer arriving as the screen opened, and again for every download that finished
/// while it was open. None of it changes until the log does, or the day.
@MainActor
private final class HistoryFigures {
    struct Log {
        let streak: Int
        let byMonth: [(date: Date, count: Int)]
        let csv: String
    }

    struct Windowed {
        let count: Int
        let seconds: Int
        let byHour: [Int]
        let artists: [ListeningHistory.Ranked]
        let albums: [ListeningHistory.Ranked]
        let songs: [ListeningHistory.Ranked]
        let genres: [ListeningHistory.Ranked]
    }

    /// What the figures were worked out from: the log's length and its two ends, and the
    /// day, which moves the windows and the streak.
    private struct Key: Equatable {
        let count: Int
        let first: UUID?
        let last: UUID?
        let day: Date
    }

    private var key: Key?
    private var madeLog: Log?
    private var madeWindows: [ListeningHistory.Window: Windowed] = [:]

    func log(of history: ListeningHistory) -> Log {
        refresh(history)
        if let madeLog { return madeLog }
        let made = Log(streak: history.streak, byMonth: history.playsByMonth(), csv: Self.csv(history.plays))
        madeLog = made
        return made
    }

    func windowed(_ window: ListeningHistory.Window, of history: ListeningHistory) -> Windowed {
        refresh(history)
        if let known = madeWindows[window] { return known }
        let made = Windowed(
            count: history.plays(in: window).count,
            seconds: history.totalSeconds(in: window),
            byHour: history.playsByHour(in: window),
            artists: history.topArtists(in: window),
            albums: history.topAlbums(in: window),
            songs: history.topSongs(in: window),
            genres: history.topGenres(in: window)
        )
        madeWindows[window] = made
        return made
    }

    /// Reading the log here is also what has the screen redraw when it changes.
    private func refresh(_ history: ListeningHistory) {
        let plays = history.plays
        let now = Key(
            count: plays.count, first: plays.first?.id, last: plays.last?.id,
            day: Calendar.current.startOfDay(for: .now)
        )
        guard now != key else { return }
        key = now
        madeLog = nil
        madeWindows = [:]
    }

    /// One row per play, so a spreadsheet can do whatever this screen does not.
    private static func csv(_ plays: [ListeningHistory.Play]) -> String {
        let formatter = ISO8601DateFormatter()
        func escaped(_ field: String) -> String {
            "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        let header = "played_at,title,artist,album,genre,seconds"
        let rows = plays.map { play in
            [
                formatter.string(from: play.at),
                escaped(play.title),
                escaped(play.artist),
                escaped(play.album),
                escaped(play.genre ?? ""),
                String(play.duration),
            ].joined(separator: ",")
        }
        return ([header] + rows).joined(separator: "\n")
    }
}

/// Its own view, because it reads the downloads catalog: in the screen's body, every
/// track a download finished redrew all of Stats, and the artwork figure is a listing of
/// a directory.
private struct StorageSection: View {
    @Environment(DownloadCenter.self) private var downloads

    var body: some View {
        Section("On This Phone") {
            LabeledContent("Downloaded", value: "\(downloads.catalog.entries.count) tracks")
            LabeledContent("Audio", value: downloads.catalog.totalBytes.asFileSize)
            LabeledContent("Artwork", value: ArtworkStore.diskUsage().asFileSize)
        }
    }
}

/// Plays by hour of day. A bar chart rather than Swift Charts: this is one axis of
/// twenty-four integers, and the framework dependency buys nothing at that size.
private struct HourChart: View {
    let values: [Int]

    var body: some View {
        let peak = max(values.max() ?? 1, 1)

        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Array(values.enumerated()), id: \.offset) { hour, value in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(value == 0 ? Color.secondary.opacity(0.15) : Color.appTint)
                        .frame(height: max(2, CGFloat(value) / CGFloat(peak) * 60))
                        .accessibilityLabel("\(hour):00, \(value) plays")
                }
            }

            HStack {
                Text("12a").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Text("12p").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Text("11p").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}

/// The last 30 days.
/// Plays per month, from the first in the log to this one: all time, like the rest.
private struct MonthChart: View {
    let months: [(date: Date, count: Int)]

    var body: some View {
        let peak = max(months.map(\.count).max() ?? 1, 1)

        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Array(months.enumerated()), id: \.offset) { _, month in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(month.count == 0 ? Color.secondary.opacity(0.15) : Color.appTint.opacity(0.8))
                        .frame(height: max(2, CGFloat(month.count) / CGFloat(peak) * 44))
                        .accessibilityLabel("\(month.date.formatted(.dateTime.month(.wide).year())): \(month.count) plays")
                }
            }
            if let first = months.first?.date {
                Text("By month, since \(first.formatted(.dateTime.month(.abbreviated).year()))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
