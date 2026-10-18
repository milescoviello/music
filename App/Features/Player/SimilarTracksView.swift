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
    @Environment(SonicService.self) private var sonic
    @Environment(\.dismiss) private var dismiss

    let song: Song

    private enum Kind: String, CaseIterable, Identifiable {
        case sonic = "Sonically Similar"
        case related = "Related"
        case comfortZone = "Outside Your Comfort Zone"
        var id: String { rawValue }
        var short: String {
            switch self {
            case .sonic: return "Similar"
            case .related: return "Related"
            case .comfortZone: return "Outside"
            }
        }
    }

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
    }

    private var footer: String {
        switch list {
        case .sonic: return "Tracks that sound most like this one, from the sonic analysis of your library."
        case .related: return "Tracks by artists your server considers similar to \(song.artist ?? "this one")."
        case .comfortZone: return "Related in sound but not close, by other artists — the ones you haven't played first."
        }
    }

    private func load() async {
        let client = appState.client
        async let sonicList = sonic.similarSongs(to: song, limit: 50)
        async let distant = sonic.distantSongs(from: song, limit: 50)
        async let related = try? client.similarSongs(toSongID: song.id, count: 50)

        results[.sonic] = await sonicList ?? []
        results[.comfortZone] = await distant ?? []
        results[.related] = (await related ?? []).filter { $0.id != song.id }
        // Sonic first when there is one, as in Plexamp.
        list = available.first ?? .related
        isLoading = false
    }
}
