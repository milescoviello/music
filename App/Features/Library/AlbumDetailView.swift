import SwiftUI

struct AlbumDetailView: View {
    @Environment(AppState.self) private var appState
    @Environment(LibraryScopeStore.self) private var scope

    let album: AlbumRef

    @State private var detail: AlbumDetail?
    @State private var selection = SongSelection()
    @State private var error: String?
    @State private var review: String?
    @State private var moreByArtist: [Album] = []
    @State private var isReviewExpanded = false

    var body: some View {
        List {
            Section {
                header
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            if let error {
                Text(error)
                    .foregroundStyle(.red)
            }

            if detail?.hasMultipleDiscs == true {
                ForEach(discs, id: \.number) { disc in
                    Section("Disc \(disc.number)") {
                        songRows(disc.songs)
                    }
                }
            } else {
                songRows(songs)
            }

            if !details.isEmpty {
                Section {
                    Text(details)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .listRowSeparator(.hidden)
                }
            }

            // Plexamp's album review, when the server's agents have one.
            if let review {
                Section("About This Album") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(review)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(isReviewExpanded ? nil : 5)
                        Button(isReviewExpanded ? "Less" : "More") {
                            withAnimation { isReviewExpanded.toggle() }
                        }
                        .font(.subheadline.weight(.medium))
                        .buttonStyle(.borderless)
                    }
                    .listRowSeparator(.hidden)
                }
            }

            if !moreByArtist.isEmpty, let artist = album.artist ?? detail?.artist {
                Section("More by \(artist)") {
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: Metrics.itemSpacing) {
                            ForEach(moreByArtist) { other in
                                NavigationLink(value: Destination.album(AlbumRef(other))) {
                                    AlbumCard(album: other)
                                        .frame(width: Metrics.cardWidth)
                                }
                                .buttonStyle(.plain)
                                .albumMenu(other)
                            }
                        }
                    }
                    .contentMargins(.horizontal, Metrics.gutter, for: .scrollContent)
                    .scrollIndicators(.hidden)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                }
            }
        }
        .listStyle(.plain)
        .playerClearance()
        .collapsingTitle(album.name)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                CollectionDownloadButton(
                    songs: songs, groupID: album.id, groupName: album.name
                )
            }
            ToolbarItem(placement: .topBarTrailing) {
                FavoriteButton(
                    id: album.id,
                    kind: .album,
                    serverValue: detail?.starred != nil
                )
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    QueueInsertItems(songs: songs)
                    Divider()
                    Button("Start Radio", systemImage: "dot.radiowaves.left.and.right") {
                        startRadio()
                    }
                    AddToPlaylistMenu(songs: songs, suggestedName: album.name)
                    Divider()
                    Button("Select Tracks", systemImage: "checkmark.circle") {
                        selection.begin()
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .disabled(songs.isEmpty)
            }

            if selection.isActive {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { selection.end() }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if selection.isActive {
                SelectionToolbar(selection: selection, all: songs, source: album.name)
            }
        }
        .task { await load() }
    }

    private var songs: [Song] { detail?.songs ?? [] }

    private var discs: [(number: Int, songs: [Song])] {
        Dictionary(grouping: songs) { $0.discNumber ?? 1 }
            .map { (number: $0.key, songs: $0.value) }
            .sorted { $0.number < $1.number }
    }

    /// Tapping any track queues the whole album, in album order, even inside a
    /// per-disc section -- so track 1 of disc 2 continues into disc 2 track 2.
    @ViewBuilder
    private func songRows(_ list: [Song]) -> some View {
        ForEach(list) { song in
            PlayableSongRow(
                songs: songs,
                index: songs.firstIndex(of: song) ?? 0,
                source: album.name,
                style: .numbered(song.track ?? 1),
                showsNavigation: false,
                selection: selection
            )
            // Separators start at the title, not under the number column.
            .alignmentGuide(.listRowSeparatorLeading) { _ in 36 }
        }
    }

    private var header: some View {
        VStack(spacing: Metrics.headerToContent) {
            ArtworkImage(
                id: album.coverArt, size: .full,
                cornerRadius: Metrics.radiusHeader, fallbackText: album.name
            )
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: Metrics.detailArtwork)
                .shadow(radius: 12, y: 6)

            VStack(spacing: 4) {
                Text(album.name)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)

                if let artist = album.artist ?? detail?.artist {
                    Text(artist)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            PlayShuffleButtons(
                onPlay: {
                    appState.player.play(songs: songs, startingAt: 0, source: album.name)
                },
                onShuffle: {
                    appState.player.play(
                        songs: songs, startingAt: 0, source: album.name, shuffled: true
                    )
                }
            )
            .padding(.horizontal, Metrics.gutter)

            HermesNoteSection(
                subject: .album(
                    id: album.id,
                    name: album.name,
                    artist: album.artist ?? detail?.artist
                )
            )
            .padding(.horizontal, Metrics.gutter)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Metrics.gutter)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let year = detail?.year { parts.append(String(year)) }
        if let count = detail?.songCount { parts.append("\(count) tracks") }
        if let duration = detail?.duration { parts.append(duration.asLongDuration) }
        return parts.joined(separator: " · ")
    }

    private func startRadio() {
        guard let seed = songs.randomElement() else { return }
        Task {
            let mix = await appState.radio.mix(seed: seed, scope: scope.scope)
            appState.startRadio(
                named: "\(album.name) Radio", songs: mix,
                station: .radio(seedIDs: songs.map(\.id), title: "\(album.name) Radio")
            )
        }
    }

    private func load() async {
        let id = album.id
        if let cached: AlbumDetail = await appState.cached(CacheKey.album(id), {
            [client = appState.client] in try await client.albumDetail(id: id)
        }) {
            detail = cached
            error = nil
        } else {
            error = "Could not load this album, and there is no saved copy."
        }

        let client = appState.client
        async let info = try? client.albumInfo(id: id)
        if let artistID = detail?.artistId,
           let artist = try? await client.artistDetail(id: artistID) {
            moreByArtist = artist.albums.filter { $0.id != id }
        }
        review = await info?.plainNotes
    }

    /// Plexamp's codec badge and the release facts the header has no room for:
    /// "FLAC 24/96 · Warp · Released 3 June 1997 · Electronic, IDM".
    private var details: String {
        var parts: [String] = []
        if let format = format { parts.append(format) }
        if let labels = detail?.recordLabels?.map(\.name).filter({ !$0.isEmpty }), !labels.isEmpty {
            parts.append(labels.joined(separator: ", "))
        }
        if let released = detail?.originalReleaseDate ?? detail?.releaseDate, let text = Self.describe(released) {
            parts.append("Released \(text)")
        }
        if let genres = detail?.genres?.map(\.name).filter({ !$0.isEmpty }), !genres.isEmpty {
            parts.append(genres.joined(separator: ", "))
        }
        return parts.joined(separator: " · ")
    }

    /// The album's format, when every track agrees on it.
    private var format: String? {
        guard let first = songs.first, let suffix = first.suffix?.uppercased(),
              songs.allSatisfy({ $0.suffix?.uppercased() == suffix })
        else { return nil }
        if let depth = first.bitDepth, let rate = first.samplingRate, rate > 0, depth > 0,
           songs.allSatisfy({ $0.bitDepth == depth && $0.samplingRate == rate }) {
            let khz = Double(rate) / 1_000
            let rateText = khz == khz.rounded() ? String(Int(khz)) : String(format: "%.1f", khz)
            return "\(suffix) \(depth)/\(rateText)"
        }
        return suffix
    }

    private static func describe(_ date: ItemDate) -> String? {
        guard let year = date.year, year > 0 else { return nil }
        guard let month = date.month,
              let parsed = Calendar.current.date(from: DateComponents(year: year, month: month, day: date.day ?? 1))
        else { return String(year) }
        return parsed.formatted(date.day == nil ? .dateTime.month(.wide).year() : .dateTime.day().month(.wide).year())
    }
}
