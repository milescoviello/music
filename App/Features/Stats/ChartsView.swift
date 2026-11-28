import SwiftUI

/// Plexamp's charts — "Aural Fixations": your top tracks, albums and artists for a week,
/// a month, a season, a year, a decade or all time, stepping back through earlier ones.
///
/// Built from the play history, which is the server's own log of every play from any
/// player, with what this app and the other devices recorded. Opens on All Time, like
/// every statistic; the shorter spans are for stepping back through.
///
/// Sections, not a screen: Charts is part of Stats (his ask, 11-27: one place, not two), so
/// these sit in Stats' own list under the all-time figures, in place of its top lists.
struct ChartsSections: View {
    @Environment(AppState.self) private var appState
    @Environment(ListeningHistory.self) private var history
    @Environment(LibraryScopeStore.self) private var scope

    @AppStorage("charts.span") private var spanRaw = ChartSpan.all.rawValue
    @AppStorage("charts.limit") private var limit = 25
    @AppStorage("charts.hemisphere") private var hemisphereRaw = Hemisphere.north.rawValue

    @State private var period: ChartPeriod?
    @State private var kind: Kind = .tracks
    @State private var serverAlbums: [Album] = []
    @State private var ranked: Ranked?

    private enum Kind: String, CaseIterable {
        case tracks = "Tracks"
        case albums = "Albums"
        case artists = "Artists"
    }

    private var span: ChartSpan { ChartSpan(rawValue: spanRaw) ?? .all }
    private var hemisphere: Hemisphere { Hemisphere(rawValue: hemisphereRaw) ?? .north }
    private var shown: ChartPeriod { period ?? ChartPeriod.current(span) }

    var body: some View {
        Section {
            Picker("Span", selection: $spanRaw) {
                ForEach(ChartSpan.allCases) { span in
                    Text(span.title).tag(span.rawValue)
                }
            }
            .pickerStyle(.menu)

            if span != .all {
                HStack {
                    Button {
                        period = shown.offset(by: -1)
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(.borderless)

                    Spacer()
                    Text(shown.title(hemisphere: hemisphere))
                        .font(.headline)
                    Spacer()

                    Button {
                        period = shown.offset(by: 1)
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .buttonStyle(.borderless)
                    .disabled(!shown.hasNext())
                }
            }

            Picker("Chart", selection: $kind) {
                ForEach(Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            Menu {
                Picker("Length", selection: $limit) {
                    ForEach(Charts.limits, id: \.self) { Text("Top \($0)").tag($0) }
                }
                Picker("Hemisphere", selection: $hemisphereRaw) {
                    Text("Northern Hemisphere").tag(Hemisphere.north.rawValue)
                    Text("Southern Hemisphere").tag(Hemisphere.south.rawValue)
                }
            } label: {
                Label("Top \(limit), \(hemisphere == .north ? "northern" : "southern") seasons", systemImage: "slider.horizontal.3")
            }
        } header: {
            Text("Charts")
        }
        .onChange(of: spanRaw) { period = nil }
        // The length is in the key too: Top 50 kept All Time's albums at 25.
        .task(id: "\(spanRaw)-\(scope.generation)-\(limit)") {
            guard span == .all else { return }
            serverAlbums = (try? await appState.client.mostPlayedAlbums(size: limit, scope: scope.scope)) ?? []
        }
        .task(id: rankKey) { await rank(rankKey) }

        Section {
            switch kind {
            case .tracks: trackRows
            case .albums: albumRows
            case .artists: artistRows
            }
        }
    }

    // MARK: - Ranking

    /// One chart, and what it was ranked for.
    private struct Ranked {
        let key: RankKey
        let rows: [ChartRow]
    }

    /// What a chart depends on: which chart, the period, its length, and the play log, by
    /// its length and its two ends.
    private struct RankKey: Equatable, Sendable {
        let kind: Kind
        let period: ChartPeriod
        let limit: Int
        let count: Int
        let first: UUID?
        let last: UUID?
    }

    private var rankKey: RankKey {
        let plays = history.plays
        return RankKey(
            kind: kind, period: shown, limit: limit,
            count: plays.count, first: plays.first?.id, last: plays.last?.id
        )
    }

    /// The chart on screen, or nil for the moment it takes to rank.
    private var rows: [ChartRow]? {
        guard let ranked, ranked.key == rankKey else { return nil }
        return ranked.rows
    }

    /// Ranked off the main thread. It is the whole log, up to 20,000 plays, mapped and
    /// counted, and in the body it ran on every redraw: every tap on the picker or the
    /// period arrows, and every server answer, rebuilt the chart from scratch.
    private func rank(_ key: RankKey) async {
        guard ranked?.key != key else { return }
        let plays = history.plays
        let rows = await Task.detached(priority: .userInitiated) { () -> [ChartRow] in
            let chart = plays.map { $0.chartPlay }
            switch key.kind {
            case .tracks: return Charts.topTracks(chart, in: key.period, limit: key.limit)
            case .albums: return Charts.topAlbums(chart, in: key.period, limit: key.limit)
            case .artists: return Charts.topArtists(chart, in: key.period, limit: key.limit)
            }
        }.value
        guard !Task.isCancelled else { return }
        ranked = Ranked(key: key, rows: rows)
    }

    // MARK: - Rows

    @ViewBuilder
    private var trackRows: some View {
        if let rows {
            trackList(rows)
        }
    }

    @ViewBuilder
    private func trackList(_ rows: [ChartRow]) -> some View {
        if rows.isEmpty {
            empty
        } else {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                Button {
                    play(fromTrack: index, rows: rows)
                } label: {
                    rowLabel(rank: index + 1, row: row)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var albumRows: some View {
        if span == .all && !serverAlbums.isEmpty {
            albumList(serverAlbums.map { album in
                ChartRow(id: album.id, title: album.name, subtitle: album.artist, plays: album.playCount ?? 0,
                         albumID: album.id, artistID: album.artistId, coverArt: album.coverArt)
            })
        } else if let rows {
            albumList(rows)
        }
    }

    @ViewBuilder
    private func albumList(_ rows: [ChartRow]) -> some View {
        if rows.isEmpty {
            empty
        } else {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if let id = row.albumID {
                    NavigationLink(value: Destination.album(AlbumRef(id: id, name: row.title, artist: row.subtitle, coverArt: row.coverArt))) {
                        rowLabel(rank: index + 1, row: row)
                    }
                } else {
                    rowLabel(rank: index + 1, row: row)
                }
            }
        }
    }

    @ViewBuilder
    private var artistRows: some View {
        if let rows {
            artistList(rows)
        }
    }

    @ViewBuilder
    private func artistList(_ rows: [ChartRow]) -> some View {
        if rows.isEmpty {
            empty
        } else {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if let id = row.artistID {
                    NavigationLink(value: Destination.artist(ArtistRef(id: id, name: row.title))) {
                        rowLabel(rank: index + 1, row: row)
                    }
                } else {
                    rowLabel(rank: index + 1, row: row)
                }
            }
        }
    }

    private func rowLabel(rank: Int, row: ChartRow) -> some View {
        HStack(spacing: Metrics.itemSpacing) {
            Text("\(rank)")
                .font(.headline.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 28)
            ArtworkImage(id: row.coverArt, size: .thumb, cornerRadius: kind == .artists ? 20 : 4)
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title).lineLimit(1)
                if let subtitle = row.subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Text(row.plays == 1 ? "1 play" : "\(row.plays) plays")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }

    private var empty: some View {
        Text(span == .all ? "Nothing played yet." : "Nothing played in this \(span.title.lowercased()).")
            .foregroundStyle(.secondary)
    }

    /// Plays the chart from the tapped track down, fetching the songs it names.
    private func play(fromTrack index: Int, rows: [ChartRow]) {
        let ids = rows[index...].compactMap(\.songID)
        let client = appState.client
        let source = "Charts · \(shown.title(hemisphere: hemisphere))"
        Task {
            // All at once, reassembled in chart order.
            var found: [Int: Song] = [:]
            await withTaskGroup(of: (Int, Song?).self) { group in
                for (offset, id) in ids.enumerated() {
                    group.addTask { (offset, try? await client.song(id: id)) }
                }
                for await (offset, song) in group {
                    if let song { found[offset] = song }
                }
            }
            let songs = ids.indices.compactMap { found[$0] }
            appState.player.play(songs: songs, startingAt: 0, source: source)
        }
    }
}
