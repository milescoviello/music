import Foundation
import Observation

/// Playlists, held once for the whole app.
///
/// Not per-view state, for a specific reason: "Add to Playlist" is offered from song
/// rows on six different screens, and each of those would otherwise fetch the playlist
/// list on appear just to populate a menu. One store means the menu is instant, and a
/// playlist created on one screen shows up in the menu on the next.
///
/// Writes go to the server first and the local copy is refreshed from the response.
/// No optimistic editing here, unlike stars: a star is one boolean that is cheap to
/// revert, whereas guessing at playlist contents risks showing a track as added when
/// it was not.
@MainActor
@Observable
final class PlaylistStore {
    private(set) var playlists: [Playlist] = []
    private(set) var isLoading = false
    /// Set after a write so the UI can confirm something happened. Cleared by whoever
    /// shows it.
    var lastMessage: String?

    private weak var client: SubsonicClient?
    private weak var appState: AppState?

    func configure(client: SubsonicClient, appState: AppState) {
        self.client = client
        self.appState = appState
    }

    func reset() {
        playlists = []
        lastMessage = nil
    }

    func load() async {
        guard let client, let appState else { return }
        isLoading = true
        // The list as last seen, at once: waiting for the server first meant a blank list
        // for the whole request timeout away from home, where the server never answers.
        if playlists.isEmpty, let saved = await appState.cache.load([Playlist].self, for: CacheKey.playlists) {
            playlists = Self.sorted(saved)
        }
        // Then the server's, saved for next time. The tracks are on the phone too, because
        // playlists are kept downloaded by default.
        if let fetched: [Playlist] = await appState.cached(CacheKey.playlists, {
            try await client.playlists()
        }) {
            playlists = Self.sorted(fetched)
        }
        isLoading = false
    }

    private static func sorted(_ playlists: [Playlist]) -> [Playlist] {
        playlists.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Loads once. Used by menus, which must not re-fetch every time they open.
    func loadIfNeeded() async {
        guard playlists.isEmpty, !isLoading else { return }
        await load()
    }

    @discardableResult
    func create(name: String, songs: [Song] = []) async -> Playlist? {
        guard let client, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }

        let created = try? await client.createPlaylist(
            name: name.trimmingCharacters(in: .whitespaces),
            songIDs: songs.map(\.id)
        )
        await load()

        if created != nil {
            lastMessage = songs.isEmpty
                ? "Created “\(name)”"
                : "Created “\(name)” with \(songs.count) \(songs.count == 1 ? "song" : "songs")"
        } else {
            lastMessage = "Could not create the playlist"
        }
        return created
    }

    /// Songs already on the playlist are left out, and the message says so. Adding a
    /// song from a long-press menu twice -- or an album that shares a track with it --
    /// used to put a second copy in, found only when it played twice. If the playlist
    /// cannot be read first, everything is added, as before.
    func add(_ songs: [Song], to playlist: Playlist) async {
        guard let client, !songs.isEmpty else { return }
        let present = Set((try? await client.playlistDetail(id: playlist.id))?.songs.map(\.id) ?? [])
        var seen = present
        let adding = songs.filter { seen.insert($0.id).inserted }
        let skipped = songs.count - adding.count

        guard !adding.isEmpty else {
            lastMessage = songs.count == 1
                ? "Already in “\(playlist.name)”"
                : "All \(songs.count) songs are already in “\(playlist.name)”"
            return
        }
        do {
            try await client.addToPlaylist(id: playlist.id, songIDs: adding.map(\.id))
            let added = adding.count == 1
                ? "Added to “\(playlist.name)”"
                : "Added \(adding.count) songs to “\(playlist.name)”"
            lastMessage = skipped == 0 ? added : "\(added) · \(skipped) already there"
            // A downloaded playlist's download follows: the new songs come down too.
            appState?.playlistSync.syncSoon()
            await load()
        } catch {
            lastMessage = "Could not add to “\(playlist.name)”"
        }
    }

    /// Removals and moves one after another, each waiting for the one before.
    @ObservationIgnored private var editing: Task<Bool, Never>?

    /// Takes `song`, shown at `index`, out of the playlist. Returns true so the detail view
    /// knows to reload.
    ///
    /// The server removes by position, and the position is looked up in the playlist as
    /// the server has it now, one removal at a time. The row's own index went stale as
    /// soon as one removal landed: the list is only reloaded afterwards, so a second song
    /// removed before that, or two removals sent together, took out the song below the one
    /// chosen.
    func remove(_ song: Song, shownAt index: Int, from playlistID: String) async -> Bool {
        let previous = editing
        let task = Task { [weak self] () -> Bool in
            _ = await previous?.value
            guard let self else { return false }
            return await self.removeNow(song, shownAt: index, from: playlistID)
        }
        editing = task
        return await task.value
    }

    /// Moves `song`, shown at `index`, in front of `anchor`, shown at `anchorIndex` -- or to
    /// the end when `anchor` is nil.
    ///
    /// Navidrome moves by position too, so this is done the way removal is: in turn, with
    /// both songs looked up in the playlist as the server has it then. Sent as the rows'
    /// indices, two moves made quickly could reach the server in either order, and the
    /// list re-read after the first could hand the next one stale positions: the wrong
    /// song moved, or the right one to the wrong place.
    func move(
        _ song: Song, shownAt index: Int, before anchor: Song?, shownAt anchorIndex: Int, in playlistID: String
    ) async {
        let previous = editing
        let task = Task { [weak self] () -> Bool in
            _ = await previous?.value
            guard let self else { return false }
            await self.moveNow(song, shownAt: index, before: anchor, shownAt: anchorIndex, in: playlistID)
            return true
        }
        editing = task
        _ = await task.value
    }

    private func moveNow(
        _ song: Song, shownAt index: Int, before anchor: Song?, shownAt anchorIndex: Int, in playlistID: String
    ) async {
        guard let client, let native = appState?.native else { return }
        do {
            let ids = try await client.playlistDetail(id: playlistID).songs.map(\.id)
            guard let position = Self.nearest(song.id, to: index, in: ids) else { return }
            let target: Int
            if let anchor {
                guard let found = Self.nearest(anchor.id, to: anchorIndex, in: ids) else { return }
                target = found
            } else {
                target = ids.count
            }
            // In front of itself or of the song after it: already there.
            guard target != position, target != position + 1 else { return }
            // Both 1-based on the server.
            try await native.movePlaylistTrack(playlistID: playlistID, from: position + 1, insertBefore: target + 1)
            // The downloaded copy's order follows.
            appState?.playlistSync.syncSoon()
        } catch {
            await Diagnostics.shared.record("playlist", "reorder failed: \(error)")
        }
    }

    /// The same song can be on a playlist twice: the copy nearest where it was shown.
    private static func nearest(_ id: String, to index: Int, in ids: [String]) -> Int? {
        ids.indices.filter { ids[$0] == id }.min { abs($0 - index) < abs($1 - index) }
    }

    private func removeNow(_ song: Song, shownAt index: Int, from playlistID: String) async -> Bool {
        guard let client else { return false }
        do {
            let ids = try await client.playlistDetail(id: playlistID).songs.map(\.id)
            // The same song can be on a playlist twice: the copy nearest where it was shown.
            guard let position = ids.indices
                .filter({ ids[$0] == song.id })
                .min(by: { abs($0 - index) < abs($1 - index) })
            else { return true }
            try await client.removeFromPlaylist(id: playlistID, indices: [position])
            // And its download: the song leaves it, deleted unless something else has it.
            appState?.playlistSync.syncSoon()
            return true
        } catch {
            lastMessage = "Could not remove that track"
            return false
        }
    }

    func rename(_ playlist: Playlist, to name: String, comment: String?) async {
        guard let client, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        do {
            try await client.renamePlaylist(
                id: playlist.id,
                name: name.trimmingCharacters(in: .whitespaces),
                comment: comment
            )
            await load()
        } catch {
            lastMessage = "Could not rename “\(playlist.name)”"
        }
    }

    func delete(_ playlist: Playlist) async {
        guard let client else { return }
        do {
            try await client.deletePlaylist(id: playlist.id)
            lastMessage = "Deleted “\(playlist.name)”"
            await load()
        } catch {
            lastMessage = "Could not delete “\(playlist.name)”"
        }
    }
}
