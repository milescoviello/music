import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Observation

/// Plexamp's "cache ahead": the tracks about to play, fetched whole onto the phone before
/// they are needed, and kept afterwards until the space is wanted.
///
/// What this buys, in order of how much it matters:
///
/// - **Sweet Fades that are measured, not guessed.** The end of a track can only be read
///   once the whole file is here, so a streamed track always got the fallback overlap.
/// - **A tunnel does not stop the music.** Fifteen tracks on Wi-Fi, five on cellular.
/// - **Seeking in converted streams.** A transcode is sent chunked with no length, so a
///   streamed one cannot be scrubbed; the same bytes from a file can.
///
/// One transfer at a time, in play order, on an ordinary foreground session: the track
/// playing is streaming over the same link, and a pile of parallel fetches would starve
/// it. Bookkeeping — which file answers which request, what to evict — is
/// `StreamCacheIndex`, which is tested; this is the plumbing around it.
@MainActor
@Observable
final class StreamCache {
    /// What to fetch: one song, as one variant, from one URL.
    struct Request: Sendable {
        let song: Song
        let variant: StreamVariant
        let url: URL
    }

    /// What is cached. Observed only when a file arrives or goes, which is all a screen
    /// shows of it, and not when one is marked used: that happens on every item the player
    /// builds and every queue change, and as an observed change it redrew the player each
    /// time, for nothing it displays.
    var index: StreamCacheIndex {
        access(keyPath: \.index)
        return storage
    }
    @ObservationIgnored private var storage = StreamCacheIndex()
    /// The song being fetched now, for the settings screen.
    private(set) var fetchingSongID: String?

    var totalBytes: Int64 { index.totalBytes }

    /// A file landed. The player swaps it in for a stream it has not started yet.
    @ObservationIgnored var onCached: ((_ songID: String, _ file: URL) -> Void)?

    /// The space the cache may use, past what is protected. Set from the settings.
    @ObservationIgnored var maxBytes: Int64 = 1 << 30 {
        didSet { if maxBytes < oldValue { evict() } }
    }

    @ObservationIgnored private var plan: [Request] = []
    /// The current track and the ones planned after it: never evicted.
    @ObservationIgnored private var protected: Set<String> = []
    /// Refused by the server this session. Not retried until the app restarts, so a track
    /// the server cannot send does not become a loop of requests.
    @ObservationIgnored private var failed: Set<String> = []
    /// Lost to the connection rather than refused: tried again later. See `FetchRetry`.
    @ObservationIgnored private var retries = FetchRetry()
    /// The last plan asked for, to come back to when a retry is due.
    @ObservationIgnored private var lastRequests: [Request] = []
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var fetchTask: Task<Void, Never>?
    /// What the fetch under way will bring, while it is still wanted.
    @ObservationIgnored private var fetchingVariant: StreamVariant?
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    private let session: URLSession
    private let directory = Paths.streamCache
    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    init() {
        let configuration = URLSessionConfiguration.default
        // A cache fetch is opportunistic: if there is no network, give up and let the
        // next plan try again, rather than holding a request open.
        #if canImport(Darwin)
        configuration.waitsForConnectivity = false
        #endif
        configuration.timeoutIntervalForRequest = 30
        session = URLSession(configuration: configuration)
        load()
    }

    // MARK: - Reading

    /// A cached file that can stand in for `wanted`, or nil to stream. Synchronous: the
    /// player asks on every item it builds.
    func file(for songID: String, satisfying wanted: StreamVariant) -> URL? {
        guard let entry = storage.entry(for: songID, satisfying: wanted) else { return nil }
        return verified(entry)
    }

    /// Any cached copy at all, whatever its quality. For when there is no network and a
    /// lower-quality file is better than nothing.
    func anyFile(for songID: String) -> URL? {
        guard let entry = storage.entries[songID] else { return nil }
        return verified(entry)
    }

    private func verified(_ entry: StreamCacheIndex.Entry) -> URL? {
        let url = directory.appendingPathComponent(entry.fileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            // Purged by iOS behind the index's back.
            withMutation(keyPath: \.index) { _ = storage.remove(entry.songID) }
            scheduleSave()
            return nil
        }
        storage.touch(entry.songID)
        scheduleSave()
        return url
    }

    // MARK: - Planning

    /// Replaces what should be on the phone, in the order it will be needed.
    ///
    /// A fetch already running carries on if its song is still wanted, and is cancelled
    /// if not — a skip past three tracks should not finish downloading the three.
    func prefetch(_ requests: [Request]) {
        protected = Set(requests.map(\.song.id))
        lastRequests = requests
        let now = Date.now
        let wanted = requests.filter { request in
            storage.entry(for: request.song.id, satisfying: request.variant) == nil
                && !failed.contains(request.song.id)
                && !retries.isWaiting(request.song.id, at: now)
        }

        if let fetching = fetchingSongID, !wanted.contains(where: { $0.song.id == fetching }) {
            fetchTask?.cancel()
            fetchingVariant = nil
        }
        // Not the one on its way. Planned again -- by a track change, or anything else
        // that moved the queue while it downloaded -- it was downloaded a second time.
        plan = wanted.filter { request in
            !(request.song.id == fetchingSongID && fetchingVariant?.satisfies(request.variant) == true)
        }
        startNext()
        scheduleRetry()
    }

    /// Stops fetching. The network went away, or nothing is playing.
    func pause() {
        plan = []
        fetchTask?.cancel()
        fetchingVariant = nil
        retryTask?.cancel()
        retryTask = nil
    }

    /// The network is back: songs that failed while it was going may be tried at once.
    func networkReturned() {
        retries.networkReturned()
    }

    /// Plans again when the first song waiting to be retried is due. Nothing else would:
    /// the next plan otherwise comes with the next track, minutes away, and a connection
    /// that drops and comes back never registers as a change of network at all.
    private func scheduleRetry() {
        retryTask?.cancel()
        retryTask = nil
        guard let due = retries.nextTry(among: lastRequests.map(\.song.id)) else { return }
        retryTask = Task { [weak self] in
            let wait = max(0, due.timeIntervalSinceNow)
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000) + 500_000_000)
            guard !Task.isCancelled, let self else { return }
            retryTask = nil
            prefetch(lastRequests)
        }
    }

    func removeAll() {
        pause()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        withMutation(keyPath: \.index) { storage.removeAll() }
        scheduleSave()
    }

    // MARK: - Fetching

    private func startNext() {
        guard fetchTask == nil, let request = plan.first else { return }
        plan.removeFirst()

        // A cache must never be what fills the phone. Zero means the figure was not
        // available, which is no reason to stop.
        let free = Paths.availableBytes
        guard free == 0 || free > 512 * 1_024 * 1_024 else {
            plan = []
            return
        }

        fetchingSongID = request.song.id
        fetchingVariant = request.variant
        fetchTask = Task { [weak self] in
            await self?.fetch(request)
            guard let self else { return }
            fetchTask = nil
            fetchingSongID = nil
            fetchingVariant = nil
            startNext()
        }
    }

    private func fetch(_ request: Request) async {
        let songID = request.song.id
        let fileName = Self.fileName(for: request.song, variant: request.variant)
        let destination = directory.appendingPathComponent(fileName)
        let started = Date.now
        // Which file, at what quality, and how long it ran: "failed" and a title, all it
        // once said, could not tell a song the server can't send from a network that
        // gave out half an hour into a transfer.
        func note(_ what: String) async {
            let elapsed = Diagnostics.duration(Date.now.timeIntervalSince(started))
            await Diagnostics.shared.record(
                "cache", "“\(request.song.title)” (\(songID), \(request.variant.label)) \(what) after \(elapsed)"
            )
        }

        do {
            // The async API leaves the temporary file for the caller to move, unlike the
            // delegate one, which deletes it the moment the callback returns. On Linux,
            // libcurl itself: URLSession there cost a slow machine a core per download.
            #if os(Linux) && canImport(CCurl)
            let (temporary, response) = try await CurlDownload.download(from: request.url, in: directory)
            #else
            let (temporary, response) = try await session.download(from: request.url)
            #endif
            defer { try? FileManager.default.removeItem(at: temporary) }

            // A Subsonic error is a 200 with a JSON body, and a 401 is still a completed
            // download; neither may be filed as music.
            let http = response as? HTTPURLResponse
            let type = http?.value(forHTTPHeaderField: "Content-Type") ?? ""
            guard (200...299).contains(http?.statusCode ?? 0),
                  !type.contains("json"), !type.contains("xml")
            else {
                failed.insert(songID)
                await note("refused: HTTP \(http?.statusCode ?? 0), \(type.isEmpty ? "no type" : type)")
                return
            }
            guard !Task.isCancelled else { return }

            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch {
            if !Task.isCancelled {
                if FetchRetry.isTransient(error) {
                    let delay = retries.failed(songID)
                    await note("failed: \(Diagnostics.describe(error)); trying again in \(Diagnostics.duration(delay))")
                    scheduleRetry()
                } else {
                    failed.insert(songID)
                    await note("failed: \(Diagnostics.describe(error))")
                }
            }
            return
        }
        retries.succeeded(songID)

        let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?
            .int64Value ?? 0
        // A slow one that worked is the warning before one that doesn't.
        if Date.now.timeIntervalSince(started) > 60 {
            await note("cached, \(size / 1_000_000) MB, slowly")
        }
        let previous = withMutation(keyPath: \.index) {
            storage.insert(StreamCacheIndex.Entry(
                songID: songID,
                variant: request.variant,
                fileName: fileName,
                bytes: size,
                lastUsed: .now
            ))
        }
        if let previous, previous.fileName != fileName {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(previous.fileName))
        }

        evict()
        scheduleSave()
        onCached?(songID, destination)
    }

    private func evict() {
        let evictions = storage.evictions(toFit: maxBytes, protecting: protected)
        if !evictions.isEmpty {
            withMutation(keyPath: \.index) {
                for entry in evictions {
                    try? FileManager.default.removeItem(at: directory.appendingPathComponent(entry.fileName))
                    storage.remove(entry.songID)
                }
            }
        }
        scheduleSave()
    }

    /// The variant is in the name, so a 128 kbps copy and the original never collide
    /// while one replaces the other. The extension has to match the bytes, or
    /// AVFoundation picks the wrong decoder.
    private static func fileName(for song: Song, variant: StreamVariant) -> String {
        let safe = song.id.replacingOccurrences(of: "/", with: "_")
        switch variant {
        case .original:
            return "\(safe).\(song.suffix ?? "audio")"
        case let .mp3(kbps):
            return "\(safe)-\(kbps).mp3"
        }
    }

    // MARK: - Persistence

    /// Reads the index and reconciles it with the directory: entries whose file is gone
    /// are dropped, and files no entry claims — a fetch killed mid-move — are deleted.
    private func load() {
        if let data = try? Data(contentsOf: indexURL),
           let stored = try? JSONDecoder().decode(StreamCacheIndex.self, from: data) {
            storage = stored
        }

        let present = Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
        for entry in storage.entries.values where !present.contains(entry.fileName) {
            storage.remove(entry.songID)
        }
        let claimed = Set(storage.entries.values.map(\.fileName))
        for name in present where name != "index.json" && !claimed.contains(name) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = storage
        let url = indexURL
        saveTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await Task.detached(priority: .utility) {
                guard let data = try? JSONEncoder().encode(snapshot) else { return }
                try? data.write(to: url, options: .atomic)
            }.value
        }
    }
}
