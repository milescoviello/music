import Foundation
import Observation

/// Stars and ratings, held in front of the server.
///
/// The problem this solves: the same song arrives from `getAlbum`, `search3`,
/// `getStarred2` and the saved queue, each a separate immutable value with its own
/// copy of `starred`. Starring one of them cannot mutate the others, so without a
/// single overlay the star you just tapped reappears un-starred the moment you
/// navigate back.
///
/// So views ask *this* for the current truth and fall back to whatever the fetch
/// said. Writes apply locally first and are reverted if the server rejects them,
/// which is what makes the tap feel instant on a phone that may be on the far end
/// of the house.
@MainActor
@Observable
final class UserStateStore {
    private var starOverrides: [String: Bool] = [:]
    private var ratingOverrides: [String: Int] = [:]
    /// Counts stars and unstars the server has taken, for lists of favourites to fetch
    /// again: they showed what they were opened with until pulled to refresh.
    private(set) var starsDelivered = 0

    private weak var client: SubsonicClient?
    private var outbox: ServerOutbox?

    func configure(client: SubsonicClient, outbox: ServerOutbox) {
        self.client = client
        self.outbox = outbox
    }

    /// Cleared on sign-out; otherwise it would leak one account's stars into another.
    func reset() {
        starOverrides.removeAll()
        ratingOverrides.removeAll()
    }

    /// Adopts the server's own answer once it is reachable again, so an override that
    /// has since been replayed stops shadowing the real value.
    func adopt(starred: Set<String>) {
        for id in starred { starOverrides[id] = true }
    }

    // MARK: - Reading

    func isStarred(id: String, serverValue: Bool) -> Bool {
        starOverrides[id] ?? serverValue
    }

    func isStarred(_ song: Song) -> Bool {
        isStarred(id: song.id, serverValue: song.isFavorite)
    }

    func isStarred(_ album: Album) -> Bool {
        isStarred(id: album.id, serverValue: album.isFavorite)
    }

    func isStarred(_ artist: Artist) -> Bool {
        isStarred(id: artist.id, serverValue: artist.starred != nil)
    }

    func rating(id: String, serverValue: Int?) -> Int {
        ratingOverrides[id] ?? serverValue ?? 0
    }

    func rating(_ song: Song) -> Int {
        rating(id: song.id, serverValue: song.userRating)
    }

    // MARK: - Writing

    func toggleStar(id: String, kind: SubsonicClient.StarKind, currentlyStarred: Bool) {
        let wanted = !currentlyStarred
        starOverrides[id] = wanted

        Task { [weak self] in
            guard let client = self?.client else { return }
            do {
                if wanted {
                    try await client.star(id: id, kind: kind)
                } else {
                    try await client.unstar(id: id, kind: kind)
                }
                self?.starsDelivered += 1
                // An older star or unstar still waiting offline would undo this one.
                await self?.outbox?.discard(id: id, kinds: [.star, .unstar])
            } catch {
                // Offline, or the server is down. Reverting would be wrong here: the
                // user's intent is not in doubt, only the delivery. So the override
                // stays and the change goes to the outbox to be replayed -- the same
                // treatment plays get, for the same reason.
                await self?.outbox?.enqueueStar(
                    id: id, target: kind.parameterName, starred: wanted
                )
            }
        }
    }

    /// The song, and the same recording in the other library with it: most songs are
    /// there twice under different ids, and a star on one copy left the other unstarred --
    /// unloved in Favourites and the mixes whenever that copy was the one listed.
    func toggleStar(_ song: Song) {
        let wanted = !isStarred(song)
        toggleStar(id: song.id, kind: .song, currentlyStarred: !wanted)
        guard let client else { return }
        Task { [weak self] in
            for copy in await Self.otherCopies(of: song, client: client) {
                guard let self, self.isStarred(copy) != wanted else { continue }
                self.toggleStar(id: copy.id, kind: .song, currentlyStarred: !wanted)
            }
        }
    }

    /// The same recording under other ids (`Song.isSameRecording`), found by its title.
    nonisolated static func otherCopies(of song: Song, client: SubsonicClient) async -> [Song] {
        guard let found = try? await client.search(query: song.title, artistCount: 0, albumCount: 0, songCount: 50)
        else { return [] }
        return found.songs.filter { $0.id != song.id && $0.isSameRecording(as: song) }
    }

    func toggleStar(_ album: Album) {
        toggleStar(id: album.id, kind: .album, currentlyStarred: isStarred(album))
    }

    func toggleStar(_ artist: Artist) {
        toggleStar(id: artist.id, kind: .artist, currentlyStarred: isStarred(artist))
    }

    /// The song and the same recording in the other library, like `toggleStar(_:)`: a
    /// rating on one copy left the other unrated, so whether a song showed as rated
    /// depended on which copy was playing.
    func setRating(_ song: Song, to rating: Int, current: Int) {
        let wanted = rating == current ? 0 : rating
        setRating(id: song.id, to: rating, current: current)
        guard let client else { return }
        Task { [weak self] in
            for copy in await Self.otherCopies(of: song, client: client) {
                guard let self, self.rating(copy) != wanted else { continue }
                self.setRating(id: copy.id, to: wanted, current: -1)
            }
        }
    }

    /// Tapping the star already showing clears the rating, the way every rating
    /// control on iOS behaves.
    func setRating(id: String, to rating: Int, current: Int) {
        let wanted = rating == current ? 0 : rating
        ratingOverrides[id] = wanted

        Task { [weak self] in
            guard let client = self?.client else { return }
            do {
                try await client.setRating(id: id, rating: wanted)
                await self?.outbox?.discard(id: id, kinds: [.rating])
            } catch {
                await self?.outbox?.enqueueRating(id: id, rating: wanted)
            }
        }
    }
}
