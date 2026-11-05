import Foundation

/// Plays that point at ids the server has since replaced.
///
/// Navidrome gives an album a new id when it is imported again (moved between the two
/// libraries, retagged, its folder renamed), and a song a new id when its file moves. The
/// history keeps the ids from the moment of each play. On 2026-11-04, 142 of the laptop's
/// 830 plays pointed at albums that no longer existed: Most Played in October showed
/// one of the most played albums as initials, and its row opened nothing.
///
/// Runs at most once a day. Every song played is looked up by id, a hundred per request.
/// A song whose album has a new id takes that album's id and artwork. A song the server
/// no longer has is looked for by title and artist, and taken only when it is plainly the
/// same recording. Ones no search would find (a single gone in a cleanup, kept as the
/// album's copy under a translated title) are linked by hand on the sonic server, and the
/// rest are named in the log, so they can be.
@MainActor
enum HistoryRepair {
    /// What a song's plays point at now.
    struct Link: Sendable, Equatable {
        var songID: String
        /// The song's own: the same as the play's, except for one linked by hand to a copy
        /// under another name (a translated title, the artist in another script).
        var title: String
        var artist: String
        var album: String
        var albumID: String
        var artistID: String?
        var coverArt: String?

        init(_ song: Song) {
            songID = song.id
            title = song.title
            artist = song.artist ?? "Unknown Artist"
            album = song.album ?? "Unknown Album"
            albumID = song.albumId ?? ""
            artistID = song.primaryArtistID
            coverArt = song.coverArt
        }
    }

    /// A new key when the repair learns something, so the next build runs it at once
    /// rather than a day after the last run: `.2` brought links made by hand.
    private static let ranKey = "history.relinkedAt.2"
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
        // Every play, not the latest: an album's latest plays can have the new id and
        // every one before them the old one.
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

        // Gone: the same recording under a new id, if the server has it. A link made by
        // hand comes first; it costs no search.
        let gone = played.values.filter { alive[$0.songID] == nil }.sorted { $0.at > $1.at }
        let byHand = gone.isEmpty ? [:] : ((try? await SonicClient(configuration: appState.sonic.configuration).historyLinks()) ?? [:])
        var found = 0
        var foundByHand = 0
        var searched = 0
        var notFound: [ListeningHistory.Play] = []
        for play in gone {
            if let id = byHand[play.songID], let song = try? await appState.client.song(id: id) {
                links[play.songID] = Link(song)
                found += 1
                foundByHand += 1
                continue
            }
            guard searched < searchLimit else { continue }
            searched += 1
            // A search that fails is not an answer: the song is looked for again next time.
            guard let candidates = try? await appState.client.search(
                query: "\(play.title) \(play.artist)", artistCount: 0, albumCount: 0, songCount: 20, scope: .all
            ).songs else { continue }
            guard let match = RecordingMatch.song(title: play.title, artist: play.artist, album: play.album, in: candidates) else {
                notFound.append(play)
                continue
            }
            links[play.songID] = Link(match)
            found += 1
        }
        let unchecked = gone.count - found - notFound.count

        let changed = appState.history.relink(links)
        defaults.set(Date.now, forKey: ranKey)
        guard changed > 0 || !notFound.isEmpty || unchecked > 0 else { return }
        await Diagnostics.shared.record(
            "history",
            "re-linked \(changed) plays to new ids (\(movedAlbums.count) albums moved, \(found) songs found again"
                + (foundByHand > 0 ? ", \(foundByHand) linked by hand" : "") + ")"
                + (notFound.isEmpty ? "" : "; \(notFound.count) songs no longer on the server")
                + (unchecked > 0 ? "; \(unchecked) more to look for next time" : "")
        )
        // By name, so each can be linked by hand on the server.
        for play in notFound.prefix(30) {
            await Diagnostics.shared.record(
                "history", "not on the server: “\(play.title)” by \(play.artist), on \(play.album) (\(play.songID))"
            )
        }
    }
}
