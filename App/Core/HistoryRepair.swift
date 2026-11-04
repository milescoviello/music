import Foundation

/// Plays that point at ids the server has since replaced.
///
/// Navidrome gives an album a new id when it is imported again (moved between the two
/// libraries, retagged, its folder renamed), and a song a new id when its file moves. The
/// history keeps the ids from the moment of each play. On 2026-11-04, 142 of the laptop's
/// 830 plays pointed at albums that no longer existed: Most Played in October showed
/// Jar of Flies (68 plays) as initials, and its row opened nothing.
///
/// Runs at most once a day. Every song played is looked up by id, a hundred per request.
/// A song whose album has a new id takes that album's id and artwork. A song the server
/// no longer has is looked for by title and artist, and taken only when it is plainly the
/// same recording.
@MainActor
enum HistoryRepair {
    /// What a song's plays point at now.
    struct Link: Sendable, Equatable {
        var songID: String
        var album: String
        var albumID: String
        var artistID: String?
        var coverArt: String?

        init(_ song: Song) {
            songID = song.id
            album = song.album ?? ""
            albumID = song.albumId ?? ""
            artistID = song.primaryArtistID
            coverArt = song.coverArt
        }
    }

    private static let ranKey = "history.relinkedAt"
    /// Launch and a regained network both sync, a moment apart.
    private static var isRunning = false
    /// Searches for songs that are gone, per run. A long history could hold hundreds.
    private static let searchLimit = 60

    static func runIfDue(_ appState: AppState) async {
        let defaults = UserDefaults.standard
        if let ran = defaults.object(forKey: ranKey) as? Date, Date.now.timeIntervalSince(ran) < 86_400 { return }
        guard !isRunning, appState.reachability.network != .offline else { return }
        isRunning = true
        defer { isRunning = false }
        await appState.history.loaded()

        // The latest play of each song, for looking one up that is gone.
        var played: [String: ListeningHistory.Play] = [:]
        for play in appState.history.plays { played[play.songID] = play }
        guard !played.isEmpty else { return }

        let current: [NavidromeClient.Song]
        do {
            current = try await appState.native.songs(ids: Array(played.keys))
        } catch {
            await Diagnostics.shared.record("history", "could not check ids: \(Diagnostics.describe(error))")
            return
        }
        let alive = Dictionary(current.filter { $0.missing != true }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        // Moved: the song is there, and some of its plays name another album id or none.
        // Every play, not the latest: Jar of Flies' latest plays had the new id, and the
        // 68 before them the old one.
        var movedAlbums: [String: Set<String>] = [:]
        for play in appState.history.plays {
            guard let song = alive[play.songID], let albumID = song.albumId, albumID != play.albumID else { continue }
            movedAlbums[albumID, default: []].insert(play.songID)
        }
        var links: [String: Link] = [:]
        for (albumID, ids) in movedAlbums {
            guard let detail = try? await appState.client.albumDetail(id: albumID) else { continue }
            for song in detail.song ?? [] where ids.contains(song.id) {
                links[song.id] = Link(song)
            }
        }

        // Gone: the same recording under a new id, if the server has it.
        let gone = played.values.filter { alive[$0.songID] == nil }.sorted { $0.at > $1.at }
        var found = 0
        for play in gone.prefix(searchLimit) {
            guard let candidates = try? await appState.client.search(
                query: "\(play.title) \(play.artist)", artistCount: 0, albumCount: 0, songCount: 20, scope: .all
            ).songs,
                let match = RecordingMatch.song(title: play.title, artist: play.artist, album: play.album, in: candidates)
            else { continue }
            links[play.songID] = Link(match)
            found += 1
        }

        let changed = appState.history.relink(links)
        defaults.set(Date.now, forKey: ranKey)
        guard changed > 0 || gone.count > found else { return }
        await Diagnostics.shared.record(
            "history",
            "re-linked \(changed) plays to new ids (\(movedAlbums.count) albums moved, \(found) songs found again)"
                + (gone.count > found ? "; \(gone.count - found) songs no longer on the server" : "")
        )
    }
}
