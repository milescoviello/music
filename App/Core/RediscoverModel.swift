import Foundation
import Observation

/// What Rediscover shows: forgotten favourites, never-played tracks, and what was
/// playing a year and a month ago. Shared by the iPhone and Linux screens.
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
