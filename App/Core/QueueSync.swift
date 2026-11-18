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
/// - **Never adopt our own save.** The server reports `changedBy`, so a queue this device
///   wrote is ignored on the way back. Without that, every launch would restore the
///   queue we had just uploaded, overwriting anything changed since. Each device saves
///   under its own name (`uploadName`): until 11-17 the phone and the desktop both saved
///   as "Music", so each took the other's queue for its own and ignored it.
/// - **Never adopt silently over a newer local queue.** The locally persisted snapshot
///   has its own timestamp; the server only wins if it is genuinely more recent
///   (`HandoffChoice`).
///
/// It is the fallback for `Handoff`, for when the device the music was on cannot be asked
/// directly: so the place is saved on every pause, and every twenty seconds while playing.
@MainActor
@Observable
final class QueueSync {
    private(set) var lastPushedAt: Date?

    struct Remote: Equatable, Sendable {
        var songs: [Song]
        var currentID: String?
        var positionSeconds: Double
        var changedBy: String
        var changedAt: Date

        /// "iPhone" for a queue saved as "Music (iPhone)"; another app's name as it is.
        var deviceName: String { QueueSync.deviceName(from: changedBy) }
    }

    /// What this device saves the queue as, for the server's `changedBy`: "Music (Laptop)".
    static var uploadName: String {
        "\(SubsonicAuth.clientName) (\(RemoteControlServer.shared.name))"
    }

    nonisolated static func deviceName(from changedBy: String) -> String {
        let prefix = "\(SubsonicAuth.clientName) ("
        guard changedBy.hasPrefix(prefix), changedBy.hasSuffix(")") else {
            return changedBy.isEmpty ? "another device" : changedBy
        }
        return String(changedBy.dropFirst(prefix.count).dropLast())
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
    /// Uploads wait until then: this device has just handed the queue to another, which
    /// owns it now, and its pause should not land on top of the other's save.
    private var holdUntil = Date.distantPast

    func configure(client: SubsonicClient) {
        self.client = client
    }

    func reset() {
        pushTask?.cancel()
        pushTask = nil
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
        guard client != nil, !queue.isEmpty, !TestCopy.isOn, holdUntil < .now else { return }
        let upload = Upload(listID: queue.listID, currentID: queue.current?.id)
        guard upload != lastPushed else { return }
        schedule(queue, elapsed: elapsed, as: upload)
    }

    /// For backgrounding — where there is no next transition to wait for, and which is
    /// when another device is most likely to pick up — so the position goes too, if it
    /// has moved since the last upload.
    func pushNow(queue: PlaybackQueue, elapsed: Double) {
        guard client != nil, !queue.isEmpty, !TestCopy.isOn, holdUntil < .now else { return }
        let upload = Upload(listID: queue.listID, currentID: queue.current?.id)
        guard upload != lastPushed || Int(elapsed) != lastPushedSeconds else { return }
        schedule(queue, elapsed: elapsed, as: upload)
    }

    /// While playing, every ten seconds or so: the place, for a device that cannot ask this
    /// one directly. Every twenty seconds at most, and not for a queue so long that each
    /// upload is a large request (a smart playlist of the whole library); those go at
    /// each change of track and each pause, as before.
    func pushPlace(queue: PlaybackQueue, elapsed: Double) {
        guard queue.order.count <= 2_000,
              Date.now.timeIntervalSince(lastPushedAt ?? .distantPast) >= 17
        else { return }
        pushNow(queue: queue, elapsed: elapsed)
    }

    /// No uploads for `seconds`: the queue has just been handed to another device.
    func holdUploads(for seconds: TimeInterval) {
        pushTask?.cancel()
        holdUntil = .now.addingTimeInterval(seconds)
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
                    positionMilliseconds: Int(elapsed * 1000),
                    client: Self.uploadName
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

    /// The queue on the server if another device saved it, whenever that was: for
    /// `Handoff` to weigh against this device's own and the paired devices'. Nil if it takes
    /// longer than `timeout`, which a press of play cannot wait out.
    func newest(within timeout: TimeInterval) async -> Remote? {
        guard let client else { return nil }
        return await Self.newest(from: client, notSavedBy: Self.uploadName, within: timeout)
    }

    /// The request, or nil once `timeout` has passed (`Race`): a press of play does not
    /// wait out a slow server.
    private nonisolated static func newest(
        from client: SubsonicClient,
        notSavedBy own: String,
        within timeout: TimeInterval
    ) async -> Remote? {
        await Race.first(of: [{
            guard let saved = try? await client.savedQueue(), !saved.songs.isEmpty,
                  let changedAt = saved.changedAt, (saved.changedBy ?? "") != own
            else { return nil }
            return Remote(
                songs: saved.songs,
                currentID: saved.current,
                positionSeconds: Double(saved.position ?? 0) / 1000,
                changedBy: saved.changedBy ?? "",
                changedAt: changedAt
            )
        }], within: timeout)
    }
}
