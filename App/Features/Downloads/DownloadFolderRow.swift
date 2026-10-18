import SwiftUI

/// One downloaded album or playlist, as Plexamp lists it: artwork, name, who it is by or
/// how many tracks, and its size — or, while it is still arriving, a ring of whole tracks
/// with the count still to come.
///
/// Reads nothing but the folder it is handed. Transfer progress is deliberately not
/// consulted: it changes many times a second while anything downloads, and every row
/// that read it would redraw with it.
struct DownloadFolderRow: View {
    let folder: DownloadFolders.Folder

    var body: some View {
        HStack(spacing: Metrics.itemSpacing) {
            ArtworkImage(
                id: folder.coverArt,
                size: .thumb,
                cornerRadius: Metrics.radiusThumb,
                playlistID: folder.kind == .playlist ? folder.key : nil,
                fallbackText: folder.name
            )
            .frame(width: Metrics.thumbPlaylist, height: Metrics.thumbPlaylist)
            .overlay {
                if folder.isDownloading {
                    DownloadRing(fraction: folder.fractionDone, remaining: folder.waiting.count)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(folder.name)
                    .lineLimit(1)
                Text(folder.artist ?? folder.trackCountText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(
                        folder.isDownloading
                            ? AnyShapeStyle(Color.appTint)
                            : AnyShapeStyle(HierarchicalShapeStyle.tertiary)
                    )
                    .lineLimit(1)
            }
        }
        .frame(minHeight: 64)
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        if folder.isDownloading {
            guard !folder.songs.isEmpty else { return "Waiting…" }
            return "\(folder.songs.count) of \(folder.trackCount) · \(folder.byteCount.asFileSize)"
        }
        return "\(folder.byteCount.asFileSize) · \(folder.duration.asLongDuration)"
    }
}

extension DownloadFolders.Folder {
    var trackCountText: String {
        "\(trackCount) \(trackCount == 1 ? "track" : "tracks")"
    }
}

/// Plexamp's download ring over the artwork: how much of the folder is here, and how
/// many tracks are still to come.
private struct DownloadRing: View {
    let fraction: Double
    let remaining: Int

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(0.5))
            Circle()
                .stroke(.white.opacity(0.25), lineWidth: 4)
                .padding(8)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(Color.appTint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(8)
            Text("\(remaining)")
                .font(.caption2.weight(.bold).monospacedDigit())
                .foregroundStyle(.white)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, 12)
        }
        .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusThumb, style: .continuous))
        .animation(.default, value: fraction)
        .accessibilityHidden(true)
    }
}

/// The long-press menu for a downloaded folder, on the Downloads list and its search.
struct DownloadFolderMenu: View {
    @Environment(AppState.self) private var appState

    let folder: DownloadFolders.Folder
    let onRemove: () -> Void

    var body: some View {
        if !folder.songs.isEmpty {
            Button("Play", systemImage: "play.fill") {
                appState.player.play(songs: folder.songs, startingAt: 0, source: folder.name)
            }
            Button("Shuffle", systemImage: "shuffle") {
                appState.player.play(
                    songs: folder.songs, startingAt: 0, source: folder.name, shuffled: true
                )
            }
            Divider()
            QueueInsertItems(songs: folder.songs)
            Divider()
        }
        Button(
            folder.isDownloading ? "Cancel and Remove" : "Remove Download",
            systemImage: "trash",
            role: .destructive,
            action: onRemove
        )
    }
}

/// Confirms taking a folder off the phone. Removing is the one destructive thing on the
/// screen, so it always asks — and it says so when the folder would only come straight
/// back because Offline & Library is set to keep it.
private struct DownloadFolderRemoval: ViewModifier {
    @Environment(AppState.self) private var appState

    @Binding var folder: DownloadFolders.Folder?
    let onRemoved: () -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Remove “\(folder?.name ?? "")” from this phone?",
            isPresented: Binding(
                get: { folder != nil },
                set: { if !$0 { folder = nil } }
            ),
            titleVisibility: .visible,
            presenting: folder
        ) { chosen in
            Button("Remove Download", role: .destructive) {
                // The folder as it is now, not as it was when the dialog opened: tracks
                // may have landed in between.
                let folders = appState.downloadFolders.folders
                let current = folders.folder(id: chosen.id) ?? chosen
                appState.downloads.remove(folders.songIDsToRemove(for: current))
                onRemoved()
            }
        } message: { chosen in
            Text(message(for: chosen))
        }
    }

    private func message(for folder: DownloadFolders.Folder) -> String {
        guard isKeptOffline(folder) else { return "It stays on your server." }
        return "It stays on your server. Offline & Library is set to keep it on this phone, "
            + "so it will download again unless you turn that off."
    }

    private func isKeptOffline(_ folder: DownloadFolders.Folder) -> Bool {
        let sync = appState.playlistSync
        guard folder.kind == .playlist, sync.isEnabled else { return false }
        if folder.key == "favourites" { return sync.includesFavourites }
        return sync.includedIDs.contains(folder.key)
    }
}

extension View {
    func downloadFolderRemoval(
        _ folder: Binding<DownloadFolders.Folder?>,
        onRemoved: @escaping () -> Void = {}
    ) -> some View {
        modifier(DownloadFolderRemoval(folder: folder, onRemoved: onRemoved))
    }
}
