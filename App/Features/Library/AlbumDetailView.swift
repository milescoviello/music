import SwiftUI

struct AlbumDetailView: View {
    @Environment(AppState.self) private var appState
    @Environment(LibraryScopeStore.self) private var scope

    let album: AlbumRef

    @State private var detail: AlbumDetail?
    @State private var selection = SongSelection()
    @State private var error: String?

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
            appState.startRadio(named: "\(album.name) Radio", songs: mix)
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
    }
}
