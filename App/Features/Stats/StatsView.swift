import SwiftUI

/// Listening statistics, and what the server holds.
///
/// Split deliberately into two kinds of number, because they answer different questions
/// and have different reach:
///
/// - **This phone** comes from the app's own play log. Navidrome does keep a per-play
///   event table, but neither its API nor Subsonic's exposes it, so anything needing
///   individual plays — time of day, streaks, "this week" — has to be recorded here as it
///   happens. These figures start from when the app was installed.
/// - **Everywhere** comes from Navidrome's own API, which unlike Subsonic returns a
///   `playDate` per song. That reaches back through the whole library, covers desktop
///   Feishin too, and includes the plays imported from Plex.
///
/// Saying which is which matters: "you played this 8 times on this phone" and "this has
/// been played 8 times" are different claims, and merging them would make the screen
/// quietly untrue.
struct StatsView: View {
    @Environment(AppState.self) private var appState
    @Environment(ListeningHistory.self) private var history

    @State private var window: ListeningHistory.Window = .month
    @State private var figures = HistoryFigures()
    @State private var confirmsClearHistory = false
    @State private var scan: ScanStatus?
    @State private var starred: Starred2?
    @State private var mostPlayed: [Album] = []
    @State private var nowPlaying: [NowPlayingEntry] = []
    @State private var recentTracks: [NavidromeClient.Song] = []
    @State private var topTracks: [NavidromeClient.Song] = []

    var body: some View {
        List {
            listeningSection
            shapeSection
            topSection
            allTimeSection
            nowPlayingSection
            librarySection
            StorageSection()
        }
        .navigationTitle("Stats")
        .playerClearance()
        .refreshable { await load() }
        .task { await load() }
    }

    // MARK: - Listening

    // Two sections now, so the builder attribute is required.
    @ViewBuilder
    private var listeningSection: some View {
        Section {
            Picker("Window", selection: $window) {
                ForEach(ListeningHistory.Window.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))

            HStack {
                figure("\(current.count)", "plays")
                Divider()
                figure(hours, "listened")
                Divider()
                figure("\(log.streak)", log.streak == 1 ? "day streak" : "day streak")
            }
            .frame(maxWidth: .infinity)
        } header: {
            Text("On This Phone")
        } footer: {
            if history.plays.isEmpty {
                Text("Nothing yet. Plays are recorded as they happen, on this phone.")
            } else {
                Text("Recorded on this phone, from when the app was installed.")
            }
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
                Text("\(history.plays.count) plays recorded on this phone. Clearing does not touch the server's own play counts.")
            }
            .confirmationDialog(
                "Delete \(history.plays.count) plays recorded on this phone?",
                isPresented: $confirmsClearHistory,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) { history.clear() }
            } message: {
                Text("This only clears what this phone recorded. Play counts on the server are unaffected.")
            }
        }
    }

    /// The play log's figures for this redraw, worked out only when the log has changed.
    private var log: HistoryFigures.Log { figures.log(of: history) }
    private var current: HistoryFigures.Windowed { figures.windowed(window, of: history) }

    private var hours: String {
        let seconds = current.seconds
        if seconds < 3_600 { return "\(seconds / 60)m" }
        let hours = Double(seconds) / 3_600
        return hours < 10
            ? String(format: "%.1fh", hours)
            : "\(Int(hours))h"
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

            DayChart(days: log.byDay)
                .frame(height: 70)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 12, trailing: 16))
        }
    }

    // MARK: - Tops

    @ViewBuilder
    private var topSection: some View {
        rankSection("Top Artists", current.artists)
        rankSection("Top Albums", current.albums)
        rankSection("Top Songs", current.songs)
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
        async let frequent = try? appState.client.albums(type: .frequent, size: 10)
        async let playing = try? appState.client.nowPlaying()
        async let recent = try? appState.native.recentlyPlayed(limit: 25)
        async let top = try? appState.native.mostPlayed(limit: 25)

        scan = await status
        starred = await stars
        mostPlayed = await frequent ?? []
        nowPlaying = await playing ?? []
        recentTracks = await recent ?? []
        topTracks = await top ?? []
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
        let byDay: [(date: Date, count: Int)]
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
        let made = Log(streak: history.streak, byDay: history.playsByDay(30), csv: Self.csv(history.plays))
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
private struct DayChart: View {
    let days: [(date: Date, count: Int)]

    var body: some View {
        let peak = max(days.map(\.count).max() ?? 1, 1)

        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(day.count == 0 ? Color.secondary.opacity(0.15) : Color.appTint.opacity(0.8))
                        .frame(height: max(2, CGFloat(day.count) / CGFloat(peak) * 44))
                }
            }
            Text("Last 30 days")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}
