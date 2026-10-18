import SwiftUI

/// The screen for everything you own and never hear.
struct RediscoverView: View {
    @Environment(AppState.self) private var appState
    @Environment(LibraryScopeStore.self) private var scope

    @State private var model = RediscoverModel()

    var body: some View {
        List {
            if !model.forgotten.songs.isEmpty {
                Section {
                    ForEach(Array(model.forgotten.songs.enumerated()), id: \.offset) { index, song in
                        PlayableSongRow(
                            songs: model.forgotten.songs,
                            index: index,
                            source: "Forgotten Favourites",
                            trailing: model.lastPlayedText(for: song)
                        )
                    }
                } header: {
                    Text("Forgotten Favourites")
                } footer: {
                    Text("Starred, and least recently played. A favourite you have never played at all comes first.")
                }
            }

            if !model.neverPlayed.isEmpty {
                Section {
                    ForEach(Array(model.neverPlayed.enumerated()), id: \.offset) { index, _ in
                        PlayableSongRow(
                            songs: model.neverPlayed,
                            index: index,
                            source: "Never Played"
                        )
                    }

                    Button {
                        Task { await model.reroll(appState: appState, scope: scope.scope) }
                    } label: {
                        Label("Show me another handful", systemImage: "arrow.triangle.2.circlepath")
                    }
                } header: {
                    Text("Never Played")
                } footer: {
                    // The figure is worth stating: it is the reason this screen exists.
                    Text("Roughly 95% of this library has never been played once.")
                }
            }

            // Dark until the app's own log is old enough. Nothing else can fill it: the
            // server keeps only the *last* play of a track, never the history of plays,
            // so "what you were playing a year ago today" is only answerable from here.
            anniversarySection("A Year Ago Today", songs: model.yearAgo)
            anniversarySection("A Month Ago", songs: model.monthAgo)
        }
        .listStyle(.insetGrouped)
        .playerClearance()
        .navigationTitle("Rediscover")
        .overlay {
            if model.isLoading, model.isEmpty { ProgressView() }
        }
        .overlay {
            if !model.isLoading, model.isEmpty {
                ContentUnavailableView(
                    "Nothing to Rediscover",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Star a few tracks, and this fills in as your library ages.")
                )
            }
        }
        .refreshable { await model.load(appState: appState, scope: scope.scope) }
        .task(id: scope.generation) {
            await model.load(appState: appState, scope: scope.scope)
        }
    }

    @ViewBuilder
    private func anniversarySection(_ title: String, songs: [Song]) -> some View {
        if !songs.isEmpty {
            Section(title) {
                ForEach(Array(songs.enumerated()), id: \.offset) { index, _ in
                    PlayableSongRow(songs: songs, index: index, source: title)
                }
            }
        }
    }
}

@MainActor
@Observable
final class RediscoverModel {
    var forgotten = Rediscovery.Forgotten()
    var neverPlayed: [Song] = []
    var yearAgo: [Song] = []
    var monthAgo: [Song] = []
    var isLoading = false

    var isEmpty: Bool {
        forgotten.songs.isEmpty && neverPlayed.isEmpty && yearAgo.isEmpty && monthAgo.isEmpty
    }

    func lastPlayedText(for song: Song) -> String {
        Rediscovery.lastPlayedText(forgotten.lastPlayed[song.id])
    }

    func load(appState: AppState, scope: LibraryScope) async {
        isLoading = true
        defer { isLoading = false }

        async let favourites = Rediscovery.forgottenFavourites(appState: appState, scope: scope)
        async let unplayed = Rediscovery.neverPlayed(appState: appState, scope: scope)

        forgotten = await favourites
        neverPlayed = await unplayed

        // Resolved one request at a time, so only run when there is actually something
        // there — which, for a log that started this month, is nothing yet.
        await appState.history.loaded()
        let year = Rediscovery.plays(from: appState.history, daysAgo: 365)
        let month = Rediscovery.plays(from: appState.history, daysAgo: 30)
        yearAgo = year.isEmpty ? [] : await Rediscovery.resolve(year, appState: appState)
        monthAgo = month.isEmpty ? [] : await Rediscovery.resolve(month, appState: appState)
    }

    func reroll(appState: AppState, scope: LibraryScope) async {
        neverPlayed = await Rediscovery.neverPlayed(appState: appState, scope: scope)
    }
}
