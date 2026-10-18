import SwiftUI

/// Everything on the phone, the way Plexamp's Downloads shows it: the albums and
/// playlists that were downloaded, each a folder to open — not every song at once, which
/// at a few hundred tracks made anything impossible to find.
///
/// This doubles as the offline browser: every entry carries its full song metadata, so
/// this screen and every folder in it render and play with the server switched off.
struct DownloadsView: View {
    @Environment(AppState.self) private var appState
    @Environment(Reachability.self) private var reachability

    /// Plexamp's `downloadsSort` and `downloadsSortAscending`, and its defaults.
    @AppStorage("downloads.sort") private var sort = DownloadFolders.Sort.addedAt
    @AppStorage("downloads.sortAscending") private var ascending = true

    @State private var removing: DownloadFolders.Folder?
    @State private var confirmsRemoveAll = false

    private var store: DownloadFolderStore { appState.downloadFolders }
    private var folders: DownloadFolders { store.folders }

    var body: some View {
        List {
            if !folders.isEmpty {
                summary
            }

            let albums = folders.sorted(folders.albums, by: sort, ascending: ascending)
            if !albums.isEmpty {
                Section("Albums") { rows(albums) }
            }

            let playlists = folders.sorted(folders.playlists, by: sort, ascending: ascending)
            if !playlists.isEmpty {
                Section("Playlists") { rows(playlists) }
            }
        }
        .listStyle(.plain)
        .playerClearance()
        .navigationTitle("Downloads")
        .toolbar {
            if !folders.isEmpty {
                ToolbarItem(placement: .topBarTrailing) { menu }
            }
        }
        .confirmationDialog(
            "Remove all downloads?",
            isPresented: $confirmsRemoveAll,
            titleVisibility: .visible
        ) {
            Button("Remove \(folders.totalBytes.asFileSize)", role: .destructive) {
                appState.downloads.removeAll()
            }
        } message: {
            Text("The music stays on your server. Only the copies on this phone are deleted.")
        }
        .downloadFolderRemoval($removing)
        .overlay {
            if folders.isEmpty {
                ContentUnavailableView(
                    "No Downloads",
                    systemImage: "arrow.down.circle",
                    description: Text(
                        "Download an album, playlist or song to keep it on this phone."
                    )
                )
            }
        }
        .onAppear { store.activate() }
    }

    private func rows(_ list: [DownloadFolders.Folder]) -> some View {
        ForEach(list) { folder in
            NavigationLink(value: Destination.downloadFolder(folder.id)) {
                DownloadFolderRow(folder: folder)
            }
            .contextMenu {
                DownloadFolderMenu(folder: folder) { removing = folder }
            }
            // No destructive role: that animates the row away before the confirmation
            // has been answered.
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button("Remove", systemImage: "trash") { removing = folder }
                    .tint(.red)
            }
        }
    }

    /// Plexamp's header over the list: how many tracks, how big, how long.
    private var summary: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(folders.songs.count) \(folders.songs.count == 1 ? "track" : "tracks")")
                .font(.headline)
            Text(totals)
                .font(.footnote)
                .foregroundStyle(.secondary)
            if !reachability.isOnline {
                Text("Offline — playing from this phone")
                    .font(.footnote)
                    .foregroundStyle(Color.appTint)
            }
        }
        .listRowSeparator(.hidden)
    }

    private var totals: String {
        var parts = [folders.totalBytes.asFileSize]
        if folders.totalDuration > 0 { parts.append(folders.totalDuration.asLongDuration) }
        return parts.joined(separator: " – ")
    }

    /// Plexamp's Downloads menu: Play All, Remove All, and the sorts, where choosing the
    /// sort already in use flips its direction.
    private var menu: some View {
        Menu {
            Button("Play All", systemImage: "play.fill") { playAll(shuffled: false) }
            Button("Shuffle All", systemImage: "shuffle") { playAll(shuffled: true) }
            Button("Remove All…", systemImage: "trash", role: .destructive) {
                confirmsRemoveAll = true
            }

            Section("Sort By") {
                ForEach(DownloadFolders.Sort.allCases, id: \.self) { option in
                    Button {
                        if sort == option { ascending.toggle() } else { sort = option }
                    } label: {
                        if sort == option {
                            Label(option.title, systemImage: ascending ? "chevron.up" : "chevron.down")
                        } else {
                            Text(option.title)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }

    private func playAll(shuffled: Bool) {
        let songs = folders.playAll(sort: sort, ascending: ascending)
        guard !songs.isEmpty else { return }
        appState.player.play(songs: songs, startingAt: 0, source: "Downloads", shuffled: shuffled)
    }
}
