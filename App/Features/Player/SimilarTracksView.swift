import SwiftUI

/// Plexamp's Show Similar Tracks, from the player's menu.
///
/// Plexamp has three lists here — sonically similar, related, and "outside your comfort
/// zone" — and the first and last need Plex's sonic analysis, which Navidrome does not do.
/// What Navidrome has is `getSimilarSongs2`: tracks by similar artists, which is Plexamp's
/// "Related Tracks". So that is the list, and it says so rather than claiming more.
struct SimilarTracksView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let song: Song

    @State private var tracks: [Song] = []
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(tracks.indices, id: \.self) { index in
                        PlayableSongRow(
                            songs: tracks,
                            index: index,
                            source: "Similar to \(song.title)",
                            showsNavigation: false
                        )
                    }
                } footer: {
                    if !tracks.isEmpty {
                        Text("Tracks by artists your server considers similar to \(song.artist ?? "this one").")
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Related Tracks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        QueueInsertItems(songs: tracks)
                        Button("Play All", systemImage: "play.fill") {
                            appState.player.play(songs: tracks, startingAt: 0, source: "Similar to \(song.title)")
                            dismiss()
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .disabled(tracks.isEmpty)
                }
            }
            .overlay {
                if isLoading {
                    ProgressView()
                } else if tracks.isEmpty {
                    ContentUnavailableView(
                        "This track is a snowflake",
                        systemImage: "snowflake",
                        description: Text("There isn't another like it — or your server has no similarity data for its artist.")
                    )
                }
            }
        }
        .task {
            let found = (try? await appState.client.similarSongs(toSongID: song.id, count: 50)) ?? []
            tracks = found.filter { $0.id != song.id }
            isLoading = false
        }
    }
}
