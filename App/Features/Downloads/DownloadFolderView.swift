import SwiftUI

/// One downloaded album or playlist, opened from the Downloads list: Plexamp's offline
/// browser for that item.
///
/// Everything here comes from the download catalog, so it plays with the server switched
/// off. It looks the folder up by id on every redraw rather than holding a copy, so tracks
/// that land while it is open appear in place.
struct DownloadFolderView: View {
    @Environment(AppState.self) private var appState
    @Environment(Reachability.self) private var reachability
    @Environment(\.dismiss) private var dismiss

    let folderID: String

    @State private var removing: DownloadFolders.Folder?

    private var store: DownloadFolderStore { appState.downloadFolders }

    var body: some View {
        Group {
            if let folder = store.folders.folder(id: folderID) {
                content(folder)
            } else {
                ContentUnavailableView(
                    "Not on This Phone",
                    systemImage: "arrow.down.circle",
                    description: Text("This is no longer in your downloads.")
                )
            }
        }
        .onAppear { store.activate() }
        .task { await refreshPlaylistOrder() }
        .downloadFolderRemoval($removing) { dismiss() }
    }

    private func content(_ folder: DownloadFolders.Folder) -> some View {
        List {
            Section {
                header(folder)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            tracks(folder)

            if !folder.waiting.isEmpty {
                Section("Still to Download · \(folder.waiting.count)") {
                    ForEach(folder.waiting) { song in
                        WaitingSongRow(song: song)
                    }
                }
            }
        }
        .listStyle(.plain)
        .playerClearance()
        .collapsingTitle(folder.name)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if !folder.songs.isEmpty {
                        QueueInsertItems(songs: folder.songs)
                        Divider()
                    }
                    if reachability.isOnline, let destination = libraryDestination(folder) {
                        NavigationLink(value: destination) {
                            Label(
                                folder.kind == .album ? "Go to Album" : "Go to Playlist",
                                systemImage: folder.kind == .album ? "square.stack" : "music.note.list"
                            )
                        }
                        Divider()
                    }
                    Button(
                        folder.isDownloading ? "Cancel and Remove" : "Remove Download",
                        systemImage: "trash",
                        role: .destructive
                    ) {
                        removing = folder
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }

    // MARK: - Tracks

    /// Tapping any track plays the folder from there, in folder order — even inside a
    /// per-disc section, so the last track of disc 1 runs on into disc 2.
    @ViewBuilder
    private func tracks(_ folder: DownloadFolders.Folder) -> some View {
        switch folder.kind {
        case .album:
            let discs = Dictionary(grouping: folder.songs.indices) { folder.songs[$0].discNumber ?? 1 }
                .sorted { $0.key < $1.key }
            if discs.count > 1 {
                ForEach(discs, id: \.key) { disc in
                    Section("Disc \(disc.key)") {
                        albumRows(folder, indices: disc.value)
                    }
                }
            } else {
                albumRows(folder, indices: Array(folder.songs.indices))
            }
        case .playlist:
            ForEach(Array(folder.songs.enumerated()), id: \.element.id) { index, _ in
                PlayableSongRow(songs: folder.songs, index: index, source: folder.name)
            }
        }
    }

    private func albumRows(_ folder: DownloadFolders.Folder, indices: [Int]) -> some View {
        ForEach(indices, id: \.self) { index in
            PlayableSongRow(
                songs: folder.songs,
                index: index,
                source: folder.name,
                style: .numbered(folder.songs[index].track ?? index + 1),
                showsNavigation: false
            )
            // Separators start at the title, not under the number column.
            .alignmentGuide(.listRowSeparatorLeading) { _ in 36 }
        }
    }

    // MARK: - Header

    private func header(_ folder: DownloadFolders.Folder) -> some View {
        VStack(spacing: Metrics.headerToContent) {
            ArtworkImage(
                id: folder.coverArt,
                size: .full,
                cornerRadius: Metrics.radiusHeader,
                playlistID: folder.kind == .playlist ? folder.key : nil,
                fallbackText: folder.name
            )
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: Metrics.detailArtwork)
            .shadow(radius: 12, y: 6)

            VStack(spacing: 4) {
                Text(folder.name)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)

                if let artist = folder.artist {
                    Text(artist)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Text(summary(folder))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            PlayShuffleButtons(
                onPlay: {
                    appState.player.play(songs: folder.songs, startingAt: 0, source: folder.name)
                },
                onShuffle: {
                    appState.player.play(
                        songs: folder.songs, startingAt: 0, source: folder.name, shuffled: true
                    )
                }
            )
            .disabled(folder.songs.isEmpty)
            .padding(.horizontal, Metrics.gutter)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Metrics.gutter)
    }

    private func summary(_ folder: DownloadFolders.Folder) -> String {
        var parts = [folder.trackCountText]
        if folder.duration > 0 { parts.append(folder.duration.asLongDuration) }
        parts.append(folder.byteCount.asFileSize)
        return parts.joined(separator: " · ")
    }

    // MARK: - Online extras

    /// The same album or playlist in the library, for when there is a server to ask.
    private func libraryDestination(_ folder: DownloadFolders.Folder) -> Destination? {
        switch folder.kind {
        case .album:
            // A song with no album id was filed under its album's name; there is no page
            // for that.
            let albumID = (folder.songs.first ?? folder.waiting.first)?.albumId
            guard albumID != nil else { return nil }
            return .album(AlbumRef(
                id: folder.key, name: folder.name, artist: folder.artist, coverArt: folder.coverArt
            ))
        case .playlist:
            if folder.key == "favourites" { return .favorites }
            if folder.key.hasPrefix("mix-") { return .dailyMix(String(folder.key.dropFirst(4))) }
            return .playlist(PlaylistRef(id: folder.key, name: folder.name, coverArt: folder.coverArt))
        }
    }

    /// The catalog only knows when each track arrived. Online, the playlist itself is asked
    /// for its order once, and the copy is cached so the order holds offline next time.
    private func refreshPlaylistOrder() async {
        guard reachability.isOnline,
              let folder = store.folders.folder(id: folderID),
              folder.kind == .playlist,
              folder.key != "favourites",
              !folder.key.hasPrefix("mix-")
        else { return }

        let key = folder.key
        guard let detail = try? await appState.client.playlistDetail(id: key) else { return }
        await appState.cache.store(detail, for: CacheKey.playlist(key))
        store.update(order: detail.songs.map(\.id), forPlaylist: key)
    }
}

/// A track asked for and not here yet. Plain on purpose: it reads no transfer progress,
/// so a long queue of these never redraws as bytes arrive.
private struct WaitingSongRow: View {
    let song: Song

    var body: some View {
        HStack(spacing: Metrics.itemSpacing) {
            Image(systemName: "arrow.down.circle.dotted")
                .foregroundStyle(.tertiary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .lineLimit(1)
                if let artist = song.artist {
                    Text(artist)
                        .font(.footnote)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Still downloading")
    }
}
