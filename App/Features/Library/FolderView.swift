import SwiftUI

/// Plexamp's Folders: the library as it sits on disk. The top level is the server's
/// folder index; every level below is one folder's subfolders, then its tracks.
struct FolderView: View {
    @Environment(AppState.self) private var appState
    @Environment(LibraryScopeStore.self) private var scope

    /// Nil for the top level.
    let folder: FolderRef?

    @State private var indexes: [ArtistIndex] = []
    @State private var directory: MusicDirectory?
    @State private var isLoading = true

    var body: some View {
        List {
            if folder == nil {
                ForEach(indexes) { index in
                    Section(index.name) {
                        ForEach(index.artists) { entry in
                            NavigationLink(value: Destination.folder(FolderRef(id: entry.id, name: entry.name))) {
                                Label(entry.name, systemImage: "folder")
                            }
                        }
                    }
                }
            } else if let directory {
                if !directory.folders.isEmpty {
                    Section {
                        ForEach(directory.folders) { child in
                            NavigationLink(value: Destination.folder(FolderRef(id: child.id, name: child.song.title))) {
                                HStack(spacing: Metrics.itemSpacing) {
                                    ArtworkImage(id: child.song.coverArt, size: .thumb, cornerRadius: Metrics.radiusThumb, fallbackText: child.song.title)
                                        .frame(width: Metrics.thumbSmall, height: Metrics.thumbSmall)
                                    Text(child.song.title).lineLimit(1)
                                }
                            }
                        }
                    }
                }

                let songs = directory.songs
                if !songs.isEmpty {
                    Section {
                        ForEach(songs.indices, id: \.self) { index in
                            PlayableSongRow(songs: songs, index: index, source: directory.name)
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(folder?.name ?? "Folders")
        .playerClearance()
        .overlay {
            if isLoading, indexes.isEmpty, directory == nil { ProgressView() }
        }
        .task(id: scope.generation) { await load() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        if let folder {
            directory = try? await appState.client.musicDirectory(id: folder.id)
        } else {
            indexes = (try? await appState.client.folderIndexes(scope: scope.scope)) ?? []
        }
    }
}

struct FolderRef: Hashable, Sendable {
    let id: String
    let name: String
}
