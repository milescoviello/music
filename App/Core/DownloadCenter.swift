import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
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
    private(set) var catalog = DownloadCatalog() {
        didSet {
            let present = Set(catalog.entries.values.compactMap(\.groupID))
                .union(catalog.pending.values.compactMap(\.groupID))
            if present != groups { groups = present }
        }
    }
    /// The albums and playlists with a download here or on its way, by group id. Its own
    /// property, changed only when one appears or goes, for the long-press menus on every
    /// album card: reading `catalog` there redrew every card on screen per finished song.
    private(set) var groups: Set<String> = []
    private(set) var progress: [String: Double] = [:] {
        didSet {
            // Its own property, changed only when the number does: the tab badge reads
            // this, and reading `progress` itself redrew the whole tab bar — the whole
            // app — on every chunk of every download.
            if progress.count != activeCount { activeCount = progress.count }
            // The same for which songs: a row only shows whether its song is arriving,
            // and reading `progress` for that redrew every visible row on every percent.
            if progress.count != arriving.count || progress.keys.contains(where: { !arriving.contains($0) }) {
                arriving = Set(progress.keys)
            }
        }
    }
    private(set) var activeCount = 0
    /// The songs with a transfer under way: `progress`'s keys, changed only when they do.
    private(set) var arriving: Set<String> = []
    private(set) var isDownloading = false

    private let store = DownloadCatalogStore()
    private let delegate = DownloadSessionDelegate()
    private var session: URLSession!
    private weak var appState: AppState?

    init() {
        #if canImport(Darwin)
        let configuration = URLSessionConfiguration.background(
            withIdentifier: "com.milescoviello.music.downloads"
        )
        // Music is an explicit user request, so it should not wait for a "better"
        // network, and it should keep going while the phone is locked.
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.allowsCellularAccess = true
        #else
        // A desktop process is not suspended when its window is not in front, so an
        // ordinary session keeps transferring; one that quits is resumed by the catalog's
        // pending entries on the next launch.
        let configuration = URLSessionConfiguration.default
        #endif

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
            resumeWaiting()
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

    /// Waiting or downloading, as `status(for:)` would say, but without the fraction, so
    /// a view that asks this is not redrawn as the fraction moves.
    func isArriving(_ songID: String) -> Bool {
        catalog.entries[songID] == nil && (arriving.contains(songID) || catalog.pending[songID] != nil)
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

        var queued: [(entry: DownloadCatalog.Entry, url: URL)] = []
        for song in wanted {
            guard let request = Self.request(for: song, quality: quality, signer: signer) else {
                continue
            }
            let entry = DownloadCatalog.Entry(
                song: song,
                filename: "\(song.id).\(request.suffix)",
                // An estimate for a transcode, exact for the original; either way the
                // real figure lands when the transfer completes.
                byteCount: quality.estimatedBytes(for: song),
                addedAt: .now,
                groupID: groupID,
                groupName: groupName,
                qualityRaw: quality.rawValue
            )
            queued.append((entry, request.url))
        }
        guard !queued.isEmpty else { return }
        // Arriving from this moment, not from when the catalog write lands: a second tap
        // in between read every song as not downloaded and queued it all again. In one
        // assignment, so `progress`'s observers hear of a whole album once.
        progress.merge(queued.map { ($0.entry.song.id, 0.0) }) { current, _ in current }
        isDownloading = true

        Task {
            // Recorded before the transfers start, so the crash window between "file
            // landed" and "catalog knows" is recoverable at launch.
            catalog = await store.markPending(queued.map(\.entry))

            var withdrawn: [String] = []
            for (entry, url) in queued {
                // Removed again while the catalog was being written.
                guard progress[entry.song.id] != nil else {
                    withdrawn.append(entry.song.id)
                    continue
                }
                let task = session.downloadTask(with: url)
                // Survives app relaunch, which an in-memory map would not.
                task.taskDescription = entry.song.id
                task.resume()
            }
            if !withdrawn.isEmpty {
                catalog = await store.remove(songIDs: withdrawn)
            }
        }

        for song in wanted {
            // Lyrics and cover art are fetched now rather than at play time: offline is
            // exactly when they cannot be fetched, and a downloaded album that loses its
            // artwork on the train is the kind of half-measure this app exists to avoid.
            Task { await cacheLyrics(for: song) }
            Task { [weak self] in
                await self?.appState?.artwork.persistAll(id: song.coverArt)
            }
        }
    }

    /// What to fetch for a song, and the extension its file is stored under.
    ///
    /// Original bytes unless asked otherwise -- except for containers iOS cannot decode,
    /// which would otherwise land on disk as a perfect copy of something unplayable.
    /// Those are fetched transcoded whatever the setting, and the stored extension has to
    /// match the bytes or AVFoundation picks the wrong decoder.
    private static func request(
        for song: Song,
        quality: DownloadQuality,
        signer: SubsonicSigner
    ) -> (url: URL, suffix: String)? {
        let bitRate = quality.maxBitRate ?? 320
        let transcode = quality != .original || PlaybackController.needsTranscode(song.suffix)
        let endpoint = transcode ? "stream.view" : "download.view"
        let query: [String: String] = transcode
            ? ["id": song.id, "format": "mp3", "maxBitRate": String(bitRate)]
            : ["id": song.id]
        guard let url = signer.url(endpoint, query) else { return nil }
        return (url, transcode ? "mp3" : (song.suffix ?? "mp3"))
    }

    @ObservationIgnored private var isResuming = false
    @ObservationIgnored private var retryScheduled = false

    /// Starts again every song still waiting with no transfer behind it.
    ///
    /// Installing a new build kills the app mid-download, and iOS cancels the background
    /// session's transfers with it: the songs stayed in the catalog as waiting, with
    /// nothing ever coming, so a playlist downloading when the phone was plugged in
    /// stopped where it was and its ring never moved again. Called once the catalog is
    /// loaded, when the server's signer is ready, on coming back to the foreground, and
    /// a minute after a transfer is interrupted. Cheap when there is nothing to do.
    func resumeWaiting() {
        guard !isResuming, !catalog.pending.isEmpty, let signer = appState?.signer else { return }
        isResuming = true
        Task {
            defer { isResuming = false }
            let running = Set(await session.allTasks.compactMap(\.taskDescription))
            var restarted: [String: Double] = [:]
            // Not one with a progress entry either: that is a download just asked for,
            // whose transfer is created once its catalog write lands.
            let orphans = catalog.pending.values.filter {
                !running.contains($0.song.id) && progress[$0.song.id] == nil
            }
            for entry in orphans {
                guard let request = Self.request(for: entry.song, quality: entry.quality, signer: signer) else {
                    continue
                }
                let task = session.downloadTask(with: request.url)
                task.taskDescription = entry.song.id
                task.resume()
                restarted[entry.song.id] = 0
            }
            guard !restarted.isEmpty else { return }
            progress.merge(restarted) { current, _ in current }
            isDownloading = true
            await Diagnostics.shared.record("download", "resumed \(restarted.count) waiting")
        }
    }

    func remove(_ songIDs: [String]) {
        // Gone from the screen at once; the files and the catalog follow. The mirror
        // too, so nothing — `resumeWaiting` least of all — sees them as still wanted
        // while the store catches up.
        let removed = Set(songIDs)
        if progress.keys.contains(where: removed.contains) {
            progress = progress.filter { !removed.contains($0.key) }
        }
        if removed.contains(where: { catalog.entries[$0] != nil || catalog.pending[$0] != nil }) {
            var mirror = catalog
            for id in removed {
                mirror.entries.removeValue(forKey: id)
                mirror.pending.removeValue(forKey: id)
            }
            catalog = mirror
        }
        isDownloading = !progress.isEmpty
        Task {
            await cancelTasks(for: songIDs)
            catalog = await store.remove(songIDs: songIDs)
        }
    }

    /// Writes any finished songs the catalog is holding back. For going to the background.
    func flushCatalog() {
        Task { await store.flush() }
    }

    func hasDownload(group groupID: String) -> Bool {
        groups.contains(groupID)
    }

    /// Removes one album's or playlist's download: see `DownloadCatalog.songIDs(downloadedAs:)`.
    func removeGroup(_ groupID: String) {
        remove(catalog.songIDs(downloadedAs: groupID))
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
        // Whole percents only: the delegate reports every few kilobytes, and each report
        // redraws whatever is watching.
        let stepped = (fraction * 100).rounded(.down) / 100
        // Only for a transfer still wanted: a cancelled one can report once more before
        // its cancellation lands, and would bring a removed song back as arriving.
        guard let current = progress[songID], current != stepped else { return }
        progress[songID] = stepped
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

    /// A transfer cut off by the network rather than refused by the server: the song
    /// stays waiting, and is asked for again a minute from now (or on the next launch or
    /// return to the foreground), instead of quietly dropping out of its album or playlist.
    func taskInterrupted(songID: String) {
        progress.removeValue(forKey: songID)
        isDownloading = !progress.isEmpty
        guard !retryScheduled else { return }
        retryScheduled = true
        Task {
            try? await Task.sleep(for: .seconds(60))
            retryScheduled = false
            resumeWaiting()
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
    /// The network going away mid-transfer, as opposed to the server saying no.
    static func isInterruption(_ code: URLError.Code) -> Bool {
        switch code {
        case .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
             .cannotFindHost, .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed,
             .callIsActive, .backgroundSessionWasDisconnected, .secureConnectionFailed:
            return true
        default:
            return false
        }
    }

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
        // Either `remove` — the catalog is already updated — or iOS, which cancels the
        // transfers of an app being replaced; those are started again at the next launch
        // by `resumeWaiting`.
        if (error as NSError).code == NSURLErrorCancelled { return }
        let interrupted = (error as? URLError).map { Self.isInterruption($0.code) } ?? false
        MainActor.assumeIsolated {
            if interrupted {
                center?.taskInterrupted(songID: songID)
            } else {
                center?.taskFailed(songID: songID)
            }
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        MainActor.assumeIsolated {
            center?.sessionDidFinishEvents()
        }
    }
}
