import SwiftUI

/// Plexamp's charts — "Aural Fixations": your top tracks, albums and artists for a week,
/// a month, a season, a year, a decade or all time, stepping back through earlier ones.
///
/// Built from this phone's own play history, because the server only knows how many times
/// something was played, never when. All Time's albums come from the server's play counts
/// as well, which reach back before the app was installed.
struct ChartsView: View {
    @Environment(AppState.self) private var appState
    @Environment(ListeningHistory.self) private var history
    @Environment(LibraryScopeStore.self) private var scope

    @AppStorage("charts.span") private var spanRaw = ChartSpan.month.rawValue
    @AppStorage("charts.limit") private var limit = 25
    @AppStorage("charts.hemisphere") private var hemisphereRaw = Hemisphere.north.rawValue

    @State private var period: ChartPeriod?
    @State private var kind: Kind = .tracks
    @State private var serverAlbums: [Album] = []

    private enum Kind: String, CaseIterable {
        case tracks = "Tracks"
        case albums = "Albums"
        case artists = "Artists"
    }

    private var span: ChartSpan { ChartSpan(rawValue: spanRaw) ?? .month }
    private var hemisphere: Hemisphere { Hemisphere(rawValue: hemisphereRaw) ?? .north }
    private var shown: ChartPeriod { period ?? ChartPeriod.current(span) }

    var body: some View {
        List {
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
            }

            Section {
                switch kind {
                case .tracks: trackRows
                case .albums: albumRows
                case .artists: artistRows
                }
            }
        }
        .navigationTitle("Charts")
        .playerClearance()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Length", selection: $limit) {
                        ForEach(Charts.limits, id: \.self) { Text("Top \($0)").tag($0) }
                    }
                    Picker("Hemisphere", selection: $hemisphereRaw) {
                        Text("Northern Hemisphere").tag(Hemisphere.north.rawValue)
                        Text("Southern Hemisphere").tag(Hemisphere.south.rawValue)
                    }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
            }
        }
        .onChange(of: spanRaw) { period = nil }
        .task(id: "\(spanRaw)-\(scope.generation)") {
            guard span == .all else { return }
            serverAlbums = (try? await appState.client.albums(type: .frequent, size: limit, scope: scope.scope)) ?? []
        }
    }

    private var plays: [ChartPlay] { history.plays.map(\.chartPlay) }

    // MARK: - Rows

    @ViewBuilder
    private var trackRows: some View {
        let rows = Charts.topTracks(plays, in: shown, limit: limit)
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
        let rows = span == .all && !serverAlbums.isEmpty
            ? serverAlbums.map { album in
                ChartRow(id: album.id, title: album.name, subtitle: album.artist, plays: album.playCount ?? 0,
                         albumID: album.id, artistID: album.artistId, coverArt: album.coverArt)
            }
            : Charts.topAlbums(plays, in: shown, limit: limit)

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
        let rows = Charts.topArtists(plays, in: shown, limit: limit)
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
