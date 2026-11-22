import SwiftUI

/// Home with no server to be had: what plays here, first. Every download shuffled, then the
/// downloaded albums and playlists, newest first. The shelves below are saved copies, whose
/// songs may need the server; these never do.
struct OnThisDeviceShelf: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let store = appState.downloadFolders
        let folders = store.folders
        Group {
            if appState.isServerUnreachable, !folders.songs.isEmpty {
                VStack(alignment: .leading, spacing: Metrics.headerToContent) {
                    ShelfHeader(title: "On This Device")
                    Text("The server can't be reached: these play here")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Metrics.gutter)
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: Metrics.itemSpacing) {
                            Button {
                                appState.player.play(songs: folders.songs, startingAt: 0, source: "Downloads", shuffled: true)
                            } label: {
                                card(cover: folders.songs.first?.coverArt, title: "Shuffle Downloads",
                                     detail: "\(folders.songs.count) \(folders.songs.count == 1 ? "song" : "songs")")
                            }
                            .buttonStyle(.plain)
                            ForEach(Array((folders.playlists + folders.albums).sorted { $0.addedAt > $1.addedAt }.prefix(24))) { folder in
                                NavigationLink(value: Destination.downloadFolder(folder.id)) {
                                    card(cover: folder.coverArt, title: folder.name,
                                         detail: folder.artist ?? "\(folder.songs.count) \(folder.songs.count == 1 ? "song" : "songs")")
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.viewAligned)
                    .contentMargins(.horizontal, Metrics.gutter, for: .scrollContent)
                    .scrollIndicators(.hidden)
                }
            }
        }
        .task { store.activate() }
    }

    private func card(cover: String?, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ArtworkImage(id: cover, size: .card, fallbackText: title)
                .frame(width: Metrics.cardWidth, height: Metrics.cardWidth)
            Text(title).font(.subheadline.weight(.medium)).lineLimit(1)
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: Metrics.cardWidth)
    }
}
