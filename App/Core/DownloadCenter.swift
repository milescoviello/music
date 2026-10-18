import Foundation
import Observation

/// Downloads, from the UI's point of view: what is on the phone, what is arriving,
/// and where a given song's bytes actually are.
///
/// One background `URLSession`, because iOS suspends the app the moment you leave it
/// and only a background session keeps transferring — which is the entire point of
/// downloading an album before a flight.
@MainActor
@Observable
final class DownloadCenter {
    enum Status: Equatable, Sendable {
        case none
        case waiting
        case downloading(fraction: Double)
        case downloaded
    }

    /// Mirrored on the main actor so views and the player can ask synchronously.
    /// A download check that has to `await` would mean every row and every track
    /// transition hops actors.
    private(set) var catalog = DownloadCatalog()
    private(set) var progress: [String: Double] = [:]
    private(set) var isDownloading = false

    private let store = DownloadCatalogStore()
    private let delegate = DownloadSessionDelegate()
    private var session: URLSession!
    private weak var appState: AppState?

    init() {
        let configuration = URLSessionConfiguration.background(
            withIdentifier: "com.milescoviello.music.downloads"
        )
        // Music is an explicit user request, so it should not wait for a "better"
        // network, and it should keep going while the phone is locked.
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.allowsCellularAccess = true

        // The delegate queue is main, so every callback is already on the actor that
        // owns this object -- no hops, and the file move can be done inline where it
        // has to be.
        session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: .main
        )
        delegate.center = self
    }

    func attach(appState: AppState) {
        self.appState = appState
        Task {
            catalog = await store.reconcile()
            await adoptRunningTasks()
            appState.playlistSync.catalogLoaded()
        }
    }

    /// A relaunched background session already has tasks in flight; without this they
    /// would complete into a UI that never showed them as running.
    private func adoptRunningTasks() async {
        let tasks = await session.allTasks
        for task in tasks {
            guard let songID = task.taskDescription else { continue }
            progress[songID] = 0
        }
        isDownloading = !tasks.isEmpty
    }

    // MARK: - Reading

    func status(for songID: String) -> Status {
        if catalog.entries[songID] != nil { return .downloaded }
        if let fraction = progress[songID] { return .downloading(fraction: fraction) }
        if catalog.pending[songID] != nil { return .waiting }
        return .none
    }

    func isDownloaded(_ songID: String) -> Bool {
        catalog.entries[songID] != nil
    }

    /// The file to play, or nil to stream. Synchronous by design: the player asks
    /// this on every track transition.
    func localURL(for songID: String) -> URL? {
        guard let entry = catalog.entries[songID] else { return nil }
        // Trust but verify: an entry whose file vanished must fall back to streaming
        // rather than handing AVPlayer a dead URL.
        return FileManager.default.fileExists(atPath: entry.url.path) ? entry.url : nil
    }

    /// True when every track in the list is local -- the condition the crossfade
    /// engine needs, since it cannot stream.
    func isFullyLocal(_ songs: [Song]) -> Bool {
        !songs.isEmpty && songs.allSatisfy { isDownloaded($0.id) }
    }

    // MARK: - Writing

    func download(
        _ songs: [Song],
        groupID: String? = nil,
        groupName: String? = nil,
        quality: DownloadQuality = .original
    ) {
        let wanted = songs.filter { status(for: $0.id) == .none }
        guard !wanted.isEmpty, let signer = appState?.signer else { return }

        for song in wanted {
            // Original bytes unless asked otherwise -- except for containers iOS cannot
            // decode, which would otherwise land on disk as a perfect copy of something
            // unplayable. Those are fetched transcoded whatever the setting, and the
            // stored extension has to match the bytes or AVFoundation picks the wrong
            // decoder.
            let bitRate = quality.maxBitRate ?? 320
            let transcode = quality != .original || PlaybackController.needsTranscode(song.suffix)
            let endpoint = transcode ? "stream.view" : "download.view"
            let query: [String: String] = transcode
                ? ["id": song.id, "format": "mp3", "maxBitRate": String(bitRate)]
                : ["id": song.id]
            guard let url = signer.url(endpoint, query) else { continue }

            let suffix = transcode ? "mp3" : (song.suffix ?? "mp3")
            let entry = DownloadCatalog.Entry(
                song: song,
                filename: "\(song.id).\(suffix)",
                // An estimate for a transcode, exact for the original; either way the
                // real figure lands when the transfer completes.
                byteCount: quality.estimatedBytes(for: song),
                addedAt: .now,
                groupID: groupID,
                groupName: groupName,
                qualityRaw: quality.rawValue
            )

            Task {
                // Recorded before the transfer starts, so the crash window between
                // "file landed" and "catalog knows" is recoverable at launch.
                catalog = await store.markPending(entry)

                let task = session.downloadTask(with: url)
                // Survives app relaunch, which an in-memory map would not.
                task.taskDescription = song.id
                progress[song.id] = 0
                isDownloading = true
                task.resume()
            }

            // Lyrics and cover art are fetched now rather than at play time: offline is
            // exactly when they cannot be fetched, and a downloaded album that loses its
            // artwork on the train is the kind of half-measure this app exists to avoid.
            Task { await cacheLyrics(for: song) }
            Task { [weak self] in
                await self?.appState?.artwork.persistAll(id: song.coverArt)
            }
        }
    }

    func remove(_ songIDs: [String]) {
        Task {
            await cancelTasks(for: songIDs)
            catalog = await store.remove(songIDs: songIDs)
            for id in songIDs { progress.removeValue(forKey: id) }
            isDownloading = !progress.isEmpty
        }
    }

    func removeAll() {
        Task {
            let running = await session.allTasks
            for task in running { task.cancel() }
            catalog = await store.removeAll()
            progress.removeAll()
            isDownloading = false
        }
    }

    private func cancelTasks(for songIDs: [String]) async {
        let wanted = Set(songIDs)
        for task in await session.allTasks {
            if let id = task.taskDescription, wanted.contains(id) {
                task.cancel()
            }
        }
    }

    private func cacheLyrics(for song: Song) async {
        guard let client = appState?.client else { return }
        guard let sets = try? await client.lyrics(songID: song.id), !sets.isEmpty else { return }
        await LyricsStore.shared.save(sets, for: song.id)
    }

    // MARK: - Delegate callbacks (already on the main actor)

    func taskProgressed(songID: String, fraction: Double) {
        progress[songID] = fraction
    }

    /// Called from `didFinishDownloadingTo` **after** the file has been moved
    /// synchronously. The move cannot be deferred into a `Task`: iOS deletes the temp
    /// file the instant the delegate method returns, which presents as downloads that
    /// complete with no file.
    func taskFinished(songID: String, byteCount: Int64) {
        progress.removeValue(forKey: songID)
        Task {
            catalog = await store.complete(songID: songID, byteCount: byteCount)
            isDownloading = !progress.isEmpty
        }
    }

    func taskFailed(songID: String) {
        let title = catalog.pending[songID]?.song.title ?? songID
        progress.removeValue(forKey: songID)
        Task {
            await Diagnostics.shared.record("download", "failed: \(title)")
            catalog = await store.cancelPending(songID: songID)
            isDownloading = !progress.isEmpty
        }
    }

    // MARK: - Background relaunch

    /// The session says when it is done, so this is the only correct place to release
    /// the handler iOS gave the app delegate.
    func sessionDidFinishEvents() {
        BackgroundSessionBridge.finish()
    }
}

/// Separate from `DownloadCenter` because `URLSessionDownloadDelegate` is an
/// Objective-C protocol and cannot be satisfied by a `@MainActor` type without
/// scattering `nonisolated` across it. The delegate queue is main, so every method
/// here really is on the main actor.
final class DownloadSessionDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    weak var center: DownloadCenter?

    /// A Subsonic error body, however it was labelled: small, and starting with its JSON
    /// or XML envelope. No audio file is under 8 KB and starts like that.
    static func isErrorBody(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard size < 8_192, let head = try? handle.read(upToCount: 64) else { return false }
        let text = String(decoding: head, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.hasPrefix("{") || text.hasPrefix("<")
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let songID = downloadTask.taskDescription, totalBytesExpectedToWrite > 0 else {
            return
        }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        MainActor.assumeIsolated {
            center?.taskProgressed(songID: songID, fraction: fraction)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let songID = downloadTask.taskDescription else { return }

        // A 401 or a Subsonic error page is still a successful HTTP download, and
        // would otherwise be filed as a music file that plays as silence.
        if let response = downloadTask.response as? HTTPURLResponse,
           !(200...299).contains(response.statusCode) {
            MainActor.assumeIsolated { center?.taskFailed(songID: songID) }
            return
        }
        // Navidrome answers a refused download — downloads disabled, a missing file —
        // with HTTP 200 and a JSON error. That is not music either.
        let type = downloadTask.response?.mimeType ?? ""
        if type.contains("json") || type.contains("xml") || DownloadSessionDelegate.isErrorBody(location) {
            MainActor.assumeIsolated { center?.taskFailed(songID: songID) }
            return
        }

        let target = center
        let entry = MainActor.assumeIsolated { target?.catalog.pending[songID] }
        guard let entry else { return }

        // Synchronous, inline, before this method returns.
        let destination = entry.url
        try? FileManager.default.removeItem(at: destination)

        do {
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            MainActor.assumeIsolated { target?.taskFailed(songID: songID) }
            return
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0

        MainActor.assumeIsolated {
            target?.taskFinished(songID: songID, byteCount: size)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error, let songID = task.taskDescription else { return }
        // A cancel is a user action; the catalog was already updated by `remove`.
        if (error as NSError).code == NSURLErrorCancelled { return }
        MainActor.assumeIsolated { center?.taskFailed(songID: songID) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        MainActor.assumeIsolated {
            center?.sessionDidFinishEvents()
        }
    }
}
