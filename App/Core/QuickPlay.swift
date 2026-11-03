import Foundation

/// The one-tap starts: Siri, Shortcuts and the Action button on the phone, the launcher's
/// right-click menu on the desktop. Here once, so both say and do the same.
enum QuickPlay: String, CaseIterable, Sendable {
    case heavyRotation = "play-heavy-rotation"
    case madeForYou = "play-made-for-you"
    case mostPlayed = "shuffle-most-played"

    var title: String {
        switch self {
        case .heavyRotation: return "Play Heavy Rotation"
        case .madeForYou: return "Play Made for You"
        case .mostPlayed: return "Shuffle Most Played"
        }
    }
}

extension AppState {
    /// Starts it, and returns what to say. `mix` counts from 1, for Made for You.
    func quickPlay(_ what: QuickPlay, mix number: Int = 1) async -> String {
        switch what {
        case .heavyRotation:
            await mixes.loadAndWait(appState: self, scope: scope.mixScope)
            guard let mix = mixes.mixes.first(where: { $0.id == "heavy" }) ?? mixes.mixes.first else {
                return "Today's mixes aren't ready. Is the server reachable?"
            }
            player.play(songs: mix.songs, startingAt: 0, source: mix.title)
            return "Playing \(mix.title)."

        case .madeForYou:
            await mixes.loadAndWait(appState: self, scope: scope.mixScope)
            let all = mixes.mixes
            guard !all.isEmpty else { return "Today's mixes aren't ready. Is the server reachable?" }
            let mix = all[min(max(number, 1), all.count) - 1]
            player.play(songs: mix.songs, startingAt: 0, source: mix.title)
            return number > all.count
                ? "There are \(all.count) mixes today, so here's the last: \(mix.title)."
                : "Playing \(mix.title)."

        case .mostPlayed:
            // The downloaded ones, so it plays with no network at all.
            let songs = downloads.catalog.entries.values
                .filter { $0.isMember(of: MostPlayedDownloads.groupID) }
                .map(\.song)
            guard songs.count >= 10 else {
                let fallback = await quickPlay(.heavyRotation)
                return "Your most played aren't downloaded yet. \(fallback)"
            }
            player.play(songs: songs, startingAt: 0, source: MostPlayedDownloads.groupName, shuffled: true)
            return "Shuffling your \(songs.count) most played."
        }
    }
}

extension AppState {
    /// The year's top songs, as songs to play: each fetched by the id of the copy last
    /// played, in the recap's order.
    func playRecap(_ recap: Recap) async -> Bool {
        let ids = history.recap(year: recap.year, limit: 50).topSongs.compactMap(\.songID)
        var found: [Int: Song] = [:]
        await withTaskGroup(of: (Int, Song?).self) { group in
            for (index, id) in ids.enumerated() {
                group.addTask { [client] in (index, try? await client.song(id: id)) }
            }
            for await (index, song) in group { found[index] = song }
        }
        let songs = ids.indices.compactMap { found[$0] }
        guard !songs.isEmpty else { return false }
        player.play(songs: songs, startingAt: 0, source: "Your \(recap.year)")
        return true
    }
}
