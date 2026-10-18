import Foundation
import Observation

/// Keeps the play queue the same on this phone and on desktop Feishin.
///
/// Subsonic stores one queue per *user*, not per client, so both apps already point at
/// the same slot — this just uses it. Start an album on the phone, open the desktop
/// client, and it is on the same track at the same second.
///
/// Two rules keep it from fighting itself:
///
/// - **Never adopt our own save.** The server reports `changedBy`, so a queue this app
///   wrote is ignored on the way back. Without that, every launch would restore the
///   queue we had just uploaded, overwriting anything changed since.
/// - **Never adopt silently over a newer local queue.** The locally persisted snapshot
///   has its own timestamp; the server only wins if it is genuinely more recent.
@MainActor
@Observable
final class QueueSync {
    /// Set when a remote queue is available and newer, so the UI can offer it rather
    /// than yanking playback out from under someone.
    private(set) var available: Remote?
    private(set) var lastPushedAt: Date?

    struct Remote: Equatable {
        var songs: [Song]
        var currentID: String?
        var positionSeconds: Double
        var changedBy: String
        var changedAt: Date
    }

    private weak var client: SubsonicClient?
    private var pushTask: Task<Void, Never>?

    /// What an upload was of: which list, and which track in it.
    private struct Upload: Equatable {
        let listID: UUID
        let currentID: String?
    }

    /// What was last uploaded, so an unchanged queue is not sent again. Each upload is
    /// every id in the queue, which for a smart playlist of the whole library is 28,000
    /// of them, and the old signature included the elapsed seconds -- so every pause sent
    /// the lot again.
    private var lastPushed: Upload?
    /// The seconds that went with it, for the one upload that is about the position.
    private var lastPushedSeconds: Int?

    func configure(client: SubsonicClient) {
        self.client = client
    }

    func reset() {
        pushTask?.cancel()
        pushTask = nil
        available = nil
        lastPushed = nil
        lastPushedSeconds = nil
        lastPushedAt = nil
    }

    // MARK: - Uploading

    /// Debounced. Called on the transitions that matter — track change, pause,
    /// backgrounding — not on a timer, because the position only needs to be roughly
    /// right for another device to pick up.
    ///
    /// Uploads only when the list or the track playing has changed since the last
    /// upload. A pause or a resume on its own is not worth re-sending the whole queue.
    func push(queue: PlaybackQueue, elapsed: Double) {
        guard client != nil, !queue.isEmpty else { return }
        let upload = Upload(listID: queue.listID, currentID: queue.current?.id)
        guard upload != lastPushed else { return }
        schedule(queue, elapsed: elapsed, as: upload)
    }

    /// For backgrounding — where there is no next transition to wait for, and which is
    /// when another device is most likely to pick up — so the position goes too, if it
    /// has moved since the last upload.
    func pushNow(queue: PlaybackQueue, elapsed: Double) {
        guard client != nil, !queue.isEmpty else { return }
        let upload = Upload(listID: queue.listID, currentID: queue.current?.id)
        guard upload != lastPushed || Int(elapsed) != lastPushedSeconds else { return }
        schedule(queue, elapsed: elapsed, as: upload)
    }

    private func schedule(_ queue: PlaybackQueue, elapsed: Double, as upload: Upload) {
        pushTask?.cancel()
        pushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self, let client else { return }

            // The ids are only gathered when an upload is actually going out, and off the
            // main actor: it is a pass over the whole queue.
            let ids = await Task.detached(priority: .utility) {
                queue.order.compactMap { index in
                    queue.tracks.indices.contains(index) ? queue.tracks[index].id : nil
                }
            }.value
            guard !ids.isEmpty, !Task.isCancelled else { return }

            do {
                try await client.saveQueue(
                    songIDs: ids,
                    currentID: upload.currentID,
                    positionMilliseconds: Int(elapsed * 1000)
                )
                lastPushed = upload
                lastPushedSeconds = Int(elapsed)
                lastPushedAt = .now
            } catch {
                // A failed sync is not worth surfacing: the local queue is already
                // persisted on disk, and the next transition retries.
            }
        }
    }

    // MARK: - Downloading

    /// Looks for a queue saved by another client. Does not apply it — that is the
    /// caller's decision, because adopting one means interrupting whatever is playing.
    func check(localSavedAt: Date?) async {
        guard let client else { return }
        guard let saved = try? await client.savedQueue(), !saved.songs.isEmpty else {
            available = nil
            return
        }

        let changedBy = saved.changedBy ?? ""
        guard changedBy != SubsonicAuth.clientName else {
            available = nil
            return
        }

        guard let changedAt = saved.changedAt else {
            available = nil
            return
        }

        // Only if genuinely newer than what this phone already has.
        if let localSavedAt, changedAt <= localSavedAt {
            available = nil
            return
        }

        available = Remote(
            songs: saved.songs,
            currentID: saved.current,
            positionSeconds: Double(saved.position ?? 0) / 1000,
            changedBy: changedBy.isEmpty ? "another device" : changedBy,
            changedAt: changedAt
        )
    }

    func dismiss() {
        available = nil
    }
}
