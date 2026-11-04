import SwiftUI

/// Plexamp's Show Similar Tracks, from the player's menu, with its three lists:
///
/// - **Sonically Similar** — the nearest tracks in our sonic analysis.
/// - **Related** — Navidrome's similar songs: tracks by similar artists, through its
///   agents.
/// - **Outside Your Comfort Zone** — related in sound but not close, by other artists,
///   unplayed first.
///
/// The two sonic lists need the sonic service; without it, or before this track has been
/// analysed, only Related is offered.
struct SimilarTracksView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let song: Song

    private typealias Kind = SimilarKind

    @State private var list: Kind = .related
    @State private var results: [Kind: [Song]] = [:]
    @State private var isLoading = true

    private var available: [Kind] {
        Kind.allCases.filter { results[$0]?.isEmpty == false }
    }

    private var tracks: [Song] { results[list] ?? [] }

    var body: some View {
        NavigationStack {
            List {
                if available.count > 1 {
                    Picker("List", selection: $list) {
                        ForEach(available) { Text($0.short).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowSeparator(.hidden)
                }

                Section {
                    ForEach(tracks.indices, id: \.self) { index in
                        PlayableSongRow(
                            songs: tracks,
                            index: index,
                            source: "\(list.rawValue) · \(song.title)",
                            showsNavigation: false
                        )
                    }
                } footer: {
                    if !tracks.isEmpty { Text(footer) }
                }
            }
            .listStyle(.plain)
            .navigationTitle(list.rawValue)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        QueueInsertItems(songs: tracks)
                        Button("Play All", systemImage: "play.fill") {
                            appState.player.play(songs: tracks, startingAt: 0, source: "\(list.rawValue) · \(song.title)")
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
                } else if available.isEmpty {
                    ContentUnavailableView(
                        "This track is a snowflake",
                        systemImage: "snowflake",
                        description: Text("There isn't another like it.")
                    )
                }
            }
        }
        .task { await load() }
        // A sheet of its own, so the tab view underneath cannot present over it.
        .playlistPicker(host: "similar")
    }

    private var footer: String { list.footer(song) }

    private func load() async {
        let lists = await appState.similarLists(to: song, limit: 50)
        results = Dictionary(uniqueKeysWithValues: lists.map { ($0.kind, $0.songs) })
        // Sonic first when there is one, as in Plexamp.
        list = available.first ?? .related
        isLoading = false
    }
}
