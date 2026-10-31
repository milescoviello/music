import Foundation
import Observation

/// Where you were in a long track.
///
/// Subsonic bookmarks, which are **per track** — unlike `savePlayQueue`, which stores one
/// position for the whole queue and is how this app and desktop Feishin share a session.
/// Those two look similar and are not: replacing the queue loses a queue position, while a
/// bookmark on a two-hour DJ set survives everything. Don't merge them.
///
/// Held in memory as a dictionary so `play` can consult it **synchronously**. A resume
/// that had to `await` would mean either starting at zero and jumping, or delaying every
/// tap on every song for the sake of the handful that are long.
@MainActor
@Observable
final class ResumeStore {
    /// Below this, resuming is more annoying than helpful: nobody wants a four-minute song
    /// to start at 2:40 because they walked away once.
    static let minimumTrackSeconds = 600.0
    /// Don't bookmark the first minute (you have lost nothing) or the last (you were
    /// nearly done, and resuming there just ends the track).
    private static let edgeSeconds = 60.0

    private(set) var positions: [String: Double] = [:]

    private weak var client: SubsonicClient?
    private weak var outbox: ServerOutbox?

    func configure(client: SubsonicClient, outbox: ServerOutbox) {
        self.client = client
        self.outbox = outbox
    }

    /// One request at launch. Bookmarks are few by nature — only long tracks get them —
    /// so this is a single small response, not a sync.
    func refresh() async {
        guard let client, let bookmarks = try? await client.bookmarks() else { return }
        positions = Dictionary(
            bookmarks.map { ($0.entry.id, $0.seconds) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// Where to start `song`, or nil to start at the beginning.
    func resumePoint(for song: Song) -> Double? {
        guard Double(song.duration ?? 0) >= Self.minimumTrackSeconds,
              let position = positions[song.id],
              position > Self.edgeSeconds
        else { return nil }
        return position
    }

    /// Records where playback stopped. Anything too near either end clears the bookmark
    /// instead of writing one.
    func note(song: Song?, elapsed: Double) {
        guard let song, Double(song.duration ?? 0) >= Self.minimumTrackSeconds else { return }

        let duration = Double(song.duration ?? 0)
        guard elapsed > Self.edgeSeconds, elapsed < duration - Self.edgeSeconds else {
            clear(songID: song.id)
            return
        }

        positions[song.id] = elapsed
        let milliseconds = Int(elapsed * 1_000)
        let id = song.id

        Task { [weak self] in
            guard let self else { return }
            do {
                try await client?.createBookmark(id: id, positionMilliseconds: milliseconds)
                await outbox?.discard(id: id, kinds: [.bookmark])
            } catch {
                // Same treatment as a play counted offline: owed to the server, sent
                // when there is one. The outbox is an actor because a background download
                // delegate writes to it too.
                await outbox?.enqueueBookmark(id: id, positionMilliseconds: milliseconds)
            }
        }
    }

    func clear(songID: String) {
        guard positions.removeValue(forKey: songID) != nil else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await client?.deleteBookmark(id: songID)
                await outbox?.discard(id: songID, kinds: [.bookmark])
            } catch {
                await outbox?.enqueueBookmark(id: songID, positionMilliseconds: nil)
            }
        }
    }
}
