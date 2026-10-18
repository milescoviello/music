import SwiftUI

/// Plexamp's Tracks: every song in the library, a page at a time.
///
/// Subsonic has no "list all songs" call; Navidrome answers `search3` with an empty query
/// with everything, paged, which is what clients that sync a whole library use. Tapping a
/// track plays the loaded list from there; the shuffle button is Library Radio, which
/// reaches the whole library rather than the pages loaded so far.
struct TracksView: View {
    @Environment(AppState.self) private var appState
    @Environment(LibraryScopeStore.self) private var scope

    @State private var songs: [Song] = []
    @State private var canLoadMore = true
    @State private var isLoading = false

    private let pageSize = 200

    var body: some View {
        List {
            ForEach(songs.indices, id: \.self) { index in
                PlayableSongRow(songs: songs, index: index, source: "Tracks")
            }

            if canLoadMore, !songs.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .task { await loadMore() }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Tracks")
        .playerClearance()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    appState.stations.play(.library)
                } label: {
                    Image(systemName: "shuffle")
                }
                .accessibilityLabel("Shuffle all tracks")
            }
        }
        .overlay {
            if songs.isEmpty {
                if isLoading {
                    ProgressView()
                } else {
                    ContentUnavailableView(
                        "No tracks listed",
                        systemImage: "music.note.list",
                        description: Text("This server does not list every track at once. Albums and Artists still have them all.")
                    )
                }
            }
        }
        .task(id: scope.generation) {
            songs = []
            canLoadMore = true
            await loadMore()
        }
    }

    private func loadMore() async {
        guard !isLoading, canLoadMore else { return }
        isLoading = true
        defer { isLoading = false }

        let page = (try? await appState.client.search(
            query: "",
            artistCount: 0,
            albumCount: 0,
            songCount: pageSize,
            songOffset: songs.count,
            scope: scope.scope
        ))?.songs ?? []

        let known = Set(songs.map(\.id))
        songs += page.filter { !known.contains($0.id) }
        canLoadMore = page.count == pageSize
    }
}
