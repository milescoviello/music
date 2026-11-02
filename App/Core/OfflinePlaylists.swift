import Foundation

/// Playlists that work without the server: what was last seen of them, at once, and a Play
/// or Shuffle that starts a queue that can actually play.
///
/// The list and each playlist were saved to disk, but only ever read after the server had
/// failed to answer, which away from home (its address is on the home network) is the whole
/// request timeout. Play and Shuffle on a row in the list asked the server directly and,
/// with no answer, did nothing at all. So offline, a playlist could only be played from
/// Downloads. Now the saved copy is read first and refreshed after, and when the server isn't
/// there, the queue is the songs that are on this device.
extension AppState {
    /// A playlist as last saved, or nil: read straight from disk, never waiting on the server.
    func savedPlaylist(_ id: String) async -> PlaylistDetail? {
        await cache.load(PlaylistDetail.self, for: CacheKey.playlist(id))
    }

    /// The playlist from the server, or the saved copy when the server doesn't answer, and
    /// which one it is. Offline, the server isn't asked.
    func playlist(_ id: String) async -> (detail: PlaylistDetail?, isSaved: Bool) {
        if reachability.network == .offline {
            return (await savedPlaylist(id), true)
        }
        let client = client
        let result = await cache.value(for: CacheKey.playlist(id)) {
            try await client.playlistDetail(id: id)
        }
        return (result.value, result.isStale)
    }

    /// What Play and Shuffle on a playlist start with: every song when the server answered,
    /// and only the songs on this device when it didn't.
    func playlistSongsToPlay(_ id: String) async -> [Song] {
        let (detail, isSaved) = await playlist(id)
        guard let songs = detail?.songs else { return [] }
        return isSaved ? playableHere(songs) : songs
    }

    /// The songs with a copy on this device, downloaded or cached, in their order. A queue of
    /// songs the server would have to send stops at the first one when there is no server:
    /// the player holds a track it can't reach rather than skip through the rest. All of
    /// them when none is here, so a tap still starts something and says why it can't play.
    func playableHere(_ songs: [Song]) -> [Song] {
        let here = songs.filter { downloads.localURL(for: $0.id) != nil || streamCache.anyFile(for: $0.id) != nil }
        return here.isEmpty ? songs : here
    }
}
