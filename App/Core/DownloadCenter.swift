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
            let present = catalog.groupIDs
            if present != groups { groups = present }
            copies = Self.copies(in: catalog)
        }
    }

    /// Downloaded songs by recording, for the same song in the other library: it streamed,
    /// and offline would not play at all, with its copy on the phone all along.
    @ObservationIgnored private var copies: [String: (songID: String, albumID: String?)] = [:]

    private static func copies(in catalog: DownloadCatalog) -> [String: (songID: String, albumID: String?)] {
        var found: [String: (songID: String, albumID: String?)] = [:]
        for entry in catalog.entries.values {
            found[PlaylistMembership.recording(entry.song)] = (entry.song.id, entry.song.albumId)
        }
        return found
    }

    /// A downloaded copy of `song` from the other library. Never one on the same album:
    /// two tracks of one album with one name are different songs.
    private func copy(of song: Song) -> String? {
        guard let copy = copies[PlaylistMembership.recording(song)], copy.songID != song.id,
              copy.albumID != song.albumId || song.albumId == nil
        else { return nil }
        return copy.songID
    }

    /// This song, or its copy in the other library, is on the device.
    func isDownloaded(_ song: Song) -> Bool {
        isDownloaded(song.id) || copy(of: song).map { isDownloaded($0) } == true
    }

    /// The file to play for this song: its own, or its copy's from the other library.
    func localURL(for song: Song) -> URL? {
        localURL(for: song.id) ?? copy(of: song).flatMap { localURL(for: $0) }
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
    /// Whether `catalog` has been read from disk yet. Until it has, it is empty.
    @ObservationIgnored private(set) var isCatalogLoaded = false
    @ObservationIgnored private var catalogReading: Task<Void, Never>?

    /// Returns once `catalog` has been read from disk. Until then every song looks not
    /// downloaded, so whatever asks where a song is before this gets the cache or a
    /// stream instead. The track restored at launch did, both times the app launched on
    /// 11-02 ("from the cache", then "from the download" seconds later for the next ones),
    /// which put the song most likely to be played straight away on the wrong copy.
    func catalogLoaded() async {
        await catalogReading?.value
    }
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
        let reading = Task {
            catalog = await store.reconcile()
            isCatalogLoaded = true
        }
        catalogReading = reading
        Task {
            await reading.value
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
        !songs.isEmpty && songs.allSatisfy { isDownloaded($0) }
    }

    // MARK: - Writing

    func download(
        _ songs: [Song],
        groupID: String? = nil,
        groupName: String? = nil,
        quality: DownloadQuality = .original
    ) {
        // Songs already here, or on their way, for another album or playlist join this
        // one too, rather than being skipped: skipped, this playlist's folder lacked them,
        // and removing the other download deleted them from under it.
        let membership = groupID.map { DownloadCatalog.Membership(id: $0, name: groupName) } ?? .own
        var joining: [String] = []
        let present = songs.filter { status(for: $0.id) != .none }.map(\.id)
        if !present.isEmpty {
            var mirror = catalog
            if mirror.join(songIDs: present, membership) {
                catalog = mirror
                joining = present
            }
        }

        let wanted = songs.filter { status(for: $0.id) == .none }
        guard !wanted.isEmpty, let signer = appState?.signer else {
            if !joining.isEmpty {
                Task { catalog = await store.join(songIDs: joining, membership) }
            }
            return
        }

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
        for (entry, _) in queued { askedAt[entry.song.id] = .now }
        isDownloading = true
        watch()

        Task {
            // In the same task as the new songs, and first, so the screen is never handed
            // a catalog from before the join after one from after it.
            if !joining.isEmpty { _ = await store.join(songIDs: joining, membership) }
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
    /// When each transfer was asked for, so one "just asked for" is told from one whose
    /// transfer has gone: both have a progress entry and no task.
    @ObservationIgnored private var askedAt: [String: Date] = [:]
    /// Each running transfer's bytes when last looked at, for one that has stopped.
    @ObservationIgnored private var lastBytes: [String: (bytes: Int64, at: Date)] = [:]
    @ObservationIgnored private var watchdog: Task<Void, Never>?

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
            let tasks = await session.allTasks
            let running = Set(tasks.compactMap(\.taskDescription))
            var restarted: [String: Double] = [:]
            // Not one just asked for either, whose transfer is created once its catalog
            // write lands. A progress entry alone no longer says that: a transfer iOS
            // cancelled left one behind, and the song was skipped here until the next
            // launch, "downloading" all the while.
            let orphans = catalog.pending.values.filter { entry in
                let id = entry.song.id
                guard !running.contains(id) else { return false }
                guard progress[id] != nil, let asked = askedAt[id] else { return true }
                return Date.now.timeIntervalSince(asked) > 30
            }
            for entry in orphans {
                guard let request = Self.request(for: entry.song, quality: entry.quality, signer: signer) else {
                    continue
                }
                let task = session.downloadTask(with: request.url)
                task.taskDescription = entry.song.id
                task.resume()
                restarted[entry.song.id] = 0
                askedAt[entry.song.id] = .now
            }
            guard !restarted.isEmpty else { return }
            progress.merge(restarted) { _, new in new }
            isDownloading = true
            watch()
            let names = orphans.prefix(3).map { "“\($0.song.title)”" }.joined(separator: ", ")
            await Diagnostics.shared.record("download", "resumed \(restarted.count) waiting: \(names)\(orphans.count > 3 ? "…" : "")")
        }
    }

    /// Every two minutes while anything is arriving and the app runs: a transfer that has
    /// received nothing for five is cancelled and asked for again, and one whose transfer
    /// has gone is started again. Before this a download could sit at "downloading" for
    /// a whole day with nothing in the log (2026-11-04: two of them).
    private func watch() {
        guard watchdog == nil else { return }
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(120))
                guard let self, !progress.isEmpty || !catalog.pending.isEmpty else { break }
                await checkStalls()
                resumeWaiting()
            }
            self?.watchdog = nil
        }
    }

    private func checkStalls() async {
        let now = Date.now
        for task in await session.allTasks {
            guard let id = task.taskDescription, catalog.pending[id] != nil else { continue }
            if task.state == .suspended {
                task.resume()
                continue
            }
            guard task.state == .running else { continue }
            let bytes = task.countOfBytesReceived
            if let last = lastBytes[id], last.bytes == bytes {
                guard now.timeIntervalSince(last.at) > 300 else { continue }
                let title = catalog.pending[id]?.song.title ?? id
                let percent = Int((progress[id] ?? 0) * 100)
                await Diagnostics.shared.record("download", "“\(title)” (\(id)) stalled at \(percent)% for five minutes: asked for again")
                lastBytes[id] = nil
                progress.removeValue(forKey: id)
                askedAt[id] = nil
                task.cancel()
            } else {
                lastBytes[id] = (bytes, now)
            }
        }
    }

    /// The songs waiting, for a report: each one's title, how far it is, and whether a
    /// transfer is behind it.
    func waitingSummary() async -> [String] {
        let tasks = await session.allTasks
        var states: [String: URLSessionTask.State] = [:]
        for task in tasks { if let id = task.taskDescription { states[id] = task.state } }
        return catalog.pending.values.sorted { $0.addedAt < $1.addedAt }.prefix(8).map { entry in
            let id = entry.song.id
            let percent = progress[id].map { "\(Int($0 * 100))%" } ?? "no progress"
            let transfer: String
            switch states[id] {
            case .running?: transfer = "transferring"
            case .suspended?: transfer = "transfer suspended"
            case .canceling?: transfer = "transfer cancelling"
            case .completed?: transfer = "transfer completed"
            case nil: transfer = "no transfer"
            @unknown default: transfer = "transfer in an unknown state"
            }
            let age = Int(Date.now.timeIntervalSince(entry.addedAt) / 60)
            return "“\(entry.song.title)” (\(id)): \(percent), \(transfer), asked for \(age) min ago"
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

    /// Ends one album's or playlist's download -- all of it, or just `songIDs`. A song
    /// another download still has stays, and only leaves this one; see
    /// `DownloadCatalog.leave`.
    ///
    /// It used to delete every song filed under the group, which with one group per song
    /// took the songs another downloaded playlist shared with it.
    func removeGroup(_ groupID: String, songIDs: Set<String>? = nil) {
        // Gone from the screen at once, as in `remove`; the files follow.
        var mirror = catalog
        let gone = mirror.leave(groupID, songIDs: songIDs)
        let removed = Set((gone.finished + gone.waiting).map(\.song.id))
        catalog = mirror
        if progress.keys.contains(where: removed.contains) {
            progress = progress.filter { !removed.contains($0.key) }
        }
        isDownloading = !progress.isEmpty
        Task {
            let result = await store.leave(groupID, songIDs: songIDs)
            await cancelTasks(for: result.removed)
            catalog = result.catalog
        }
    }

    /// Removes a Downloads-screen folder: its album's or playlist's download when it has
    /// one, so songs other downloads share stay; otherwise -- songs downloaded one at a
    /// time with no album id to file them by -- `songIDs`, the songs only it shows.
    func removeFolder(key: String, otherwise songIDs: [String]) {
        if catalog.songIDs(downloadedAs: key).isEmpty {
            remove(songIDs)
        } else {
            removeGroup(key)
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
        askedAt[songID] = nil
        lastBytes[songID] = nil
        Task {
            catalog = await store.complete(songID: songID, byteCount: byteCount)
            isDownloading = !progress.isEmpty
            appState?.mostPlayed.advance()
        }
    }

    /// A transfer cut off by the network rather than refused by the server: the song
    /// stays waiting, and is asked for again a minute from now (or on the next launch or
    /// return to the foreground), instead of quietly dropping out of its album or playlist.
    func taskInterrupted(songID: String, reason: String) {
        let title = catalog.pending[songID]?.song.title ?? songID
        Task { await Diagnostics.shared.record("download", "“\(title)” (\(songID)) interrupted, trying again in a minute: \(reason)") }
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

    /// A transfer that finished, or was cancelled by iOS, for a song no longer waiting:
    /// the file is let go. It used to be left "downloading" for good, with nothing in the
    /// log; a playlist sync asking for a song it already had was one way to get there.
    func taskOrphaned(songID: String, what: String) {
        guard progress[songID] != nil else { return }
        progress.removeValue(forKey: songID)
        askedAt[songID] = nil
        lastBytes[songID] = nil
        isDownloading = !progress.isEmpty
        let title = catalog.entries[songID]?.song.title ?? songID
        Task { await Diagnostics.shared.record("download", "“\(title)” (\(songID)) \(what), but was no longer waiting") }
    }

    /// Cancelled by iOS rather than by a removal: waiting still, so it is asked for again.
    func taskCancelled(songID: String) {
        guard catalog.pending[songID] != nil else {
            taskOrphaned(songID: songID, what: "was cancelled")
            return
        }
        guard progress[songID] != nil else { return }
        taskInterrupted(songID: songID, reason: "cancelled by iOS")
    }

    /// `reason` is what went wrong, for the log: a title alone could not say.
    func taskFailed(songID: String, reason: String) {
        let title = catalog.pending[songID]?.song.title ?? songID
        progress.removeValue(forKey: songID)
        Task {
            await Diagnostics.shared.record("download", "“\(title)” (\(songID)) failed: \(reason)")
            catalog = await store.cancelPending(songID: songID)
            isDownloading = !progress.isEmpty
            appState?.mostPlayed.advance()
        }
    }

    // MARK: - Background relaunch

    /// The session says when it is done, so this is the only correct place to release
    /// the handler iOS gave the app delegate.
    func sessionDidFinishEvents() {
        // Woken in the background because a batch finished: queue the next before giving
        // the time back, which is how the most-played downloads carry on overnight.
        Task {
            await appState?.mostPlayed.advance()?.value
            BackgroundSessionBridge.finish()
        }
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

    /// A song's waiting entry as the catalog file has it. Every waiting entry is written
    /// there before its transfer starts.
    static func pendingOnDisk(_ songID: String) -> DownloadCatalog.Entry? {
        guard let data = try? Data(contentsOf: Paths.catalog),
              let catalog = try? JSONDecoder().decode(DownloadCatalog.self, from: data)
        else { return nil }
        return catalog.pending[songID]
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
            let status = response.statusCode
            MainActor.assumeIsolated { center?.taskFailed(songID: songID, reason: "HTTP \(status)") }
            return
        }
        // Navidrome answers a refused download — downloads disabled, a missing file —
        // with HTTP 200 and a JSON error. That is not music either.
        let type = downloadTask.response?.mimeType ?? ""
        if type.contains("json") || type.contains("xml") || DownloadSessionDelegate.isErrorBody(location) {
            MainActor.assumeIsolated { center?.taskFailed(songID: songID, reason: "the server sent an error, not audio") }
            return
        }

        let target = center
        // Asked of the file on disk until the catalog has been read. A relaunch in the
        // background to be handed finished downloads is exactly that moment, and the
        // empty catalog in memory had none of them waiting: their files were let go, and
        // the songs downloaded again from the start.
        let entry = MainActor.assumeIsolated { () -> DownloadCatalog.Entry? in
            guard let target else { return nil }
            return target.isCatalogLoaded ? target.catalog.pending[songID] : Self.pendingOnDisk(songID)
        }
        guard let entry else {
            MainActor.assumeIsolated { target?.taskOrphaned(songID: songID, what: "finished") }
            return
        }

        // Synchronous, inline, before this method returns.
        let destination = entry.url
        try? FileManager.default.removeItem(at: destination)

        do {
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            let reason = "couldn't keep the file: \(Diagnostics.describe(error))"
            MainActor.assumeIsolated { target?.taskFailed(songID: songID, reason: reason) }
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
        if (error as NSError).code == NSURLErrorCancelled {
            // A removal has already cleared it; anything else still waiting is asked for
            // again rather than left "downloading".
            MainActor.assumeIsolated { center?.taskCancelled(songID: songID) }
            return
        }
        let interrupted = (error as? URLError).map { Self.isInterruption($0.code) } ?? false
        let reason = Diagnostics.describe(error)
        MainActor.assumeIsolated {
            if interrupted {
                center?.taskInterrupted(songID: songID, reason: reason)
            } else {
                center?.taskFailed(songID: songID, reason: reason)
            }
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        MainActor.assumeIsolated {
            center?.sessionDidFinishEvents()
        }
    }
}
