import Foundation
import Observation

/// Composition root: owns the session and every long-lived store, and hands them
/// to SwiftUI through the environment. Deliberately not a singleton -- everything
/// is injected so there is one place to see what the app is made of.
@MainActor
@Observable
final class AppState {
    enum Phase: Equatable {
        case loading
        case needsSetup
        case ready
    }

    private(set) var phase: Phase = .loading
    private(set) var credentials: SubsonicClient.Credentials?
    /// Synchronous URL builder for media endpoints, held here so the player and the
    /// artwork cache can build URLs without awaiting the client actor.
    private(set) var signer: SubsonicSigner?
    /// True when the last library fetch fell back to disk. Drives the offline banner.
    var isShowingCachedData = false

    let client = SubsonicClient()
    let artwork = ArtworkStore()
    let scope = LibraryScopeStore()
    let userState = UserStateStore()
    let playlistStore = PlaylistStore()
    let requests = MusicRequestService()
    let queueSync = QueueSync()
    let playlistSync = PlaylistSync()
    let cache = LibraryCache()
    let playlistArtwork = PlaylistArtwork()
    let history = ListeningHistory()
    let mixes = DailyMixes()
    let hermes = HermesAsk()
    let recentSearches = RecentSearches()
    let navigator = Navigator()
    let screenAwake = ScreenAwake()
    let resume = ResumeStore()
    let native = NavidromeClient()
    let downloads = DownloadCenter()
    let reachability = Reachability()
    let outbox = ServerOutbox()
    let sleepTimer = SleepTimer()
    let audio = AudioSettings()
    let streaming = StreamingSettings()
    let playerSettings = PlayerSettings()
    let autoplay = AutoplayService()
    let guestDJ = GuestDJService()
    let stations = StationService()
    let libraryIndex = LibraryIndex()
    let recentPlays = RecentPlaysStore()
    let streamCache = StreamCache()
    let shapes = TrackShapeStore()
    /// Shared PCM ring. One buffer for the whole app, because only one thing can be
    /// visualised at a time and it must survive an output switch.
    let spectrumBuffer = AudioSampleBuffer()
    let spectrum: SpectrumAnalyser
    let player = PlaybackController()

    init() {
        spectrum = SpectrumAnalyser(buffer: spectrumBuffer)

        // Directories must exist before anything touches disk, and before a
        // background download session can be relaunched into.
        Paths.bootstrap()
        userState.configure(client: client, outbox: outbox)
        resume.configure(client: client, outbox: outbox)
        playlistStore.configure(client: client, appState: self)
        requests.configure(client: client)
        hermes.configure(requests: requests)
        queueSync.configure(client: client)
        playlistSync.configure(
            client: client, downloads: downloads, reachability: reachability
        )
        downloads.attach(appState: self)
        autoplay.configure(appState: self)
        guestDJ.configure(appState: self)
        stations.configure(appState: self)
        libraryIndex.configure(appState: self)
        player.attach(appState: self)

        sleepTimer.onFire = { [weak self] in
            self?.player.fadeOutAndPause()
        }

        audio.onTransitionsChange = { [weak self] in
            self?.player.transitionSettingsChanged()
        }

        streaming.onChange = { [weak self] in
            self?.player.streamingSettingsChanged()
        }
        reachability.onNetworkChange = { [weak self] in
            self?.player.networkChanged()
        }

        // Plays recorded while offline reach the server the moment there is one.
        reachability.onCameOnline = { [weak self] in
            Task { await self?.flushOutbox() }
        }

        // Intents cannot be injected into, so the running app is published here for
        // them to find. Set last, once everything above is wired.
        MusicIntentBridge.appState = self

        Task { await restore() }
    }

    /// Restores a saved session on launch. A stored credential is trusted without a
    /// round trip, so the app reaches `.ready` with no network at all -- which is
    /// what lets downloaded music play offline from a cold launch.
    func restore() async {
        guard let saved = Keychain.loadCredentials() else {
            phase = .needsSetup
            return
        }

        credentials = saved
        await client.configure(saved)
        await native.configure(saved)
        signer = await client.makeSigner()
        artwork.configure(signer: signer)
        phase = .ready

        await player.restore()
        await flushOutbox()
        await refreshRequests()

        // Both are cheap when there is nothing to do, and both want to happen once the
        // credentials are known rather than at construction.
        await resume.refresh()
        await queueSync.check(localSavedAt: player.lastSavedAt)
        await playlistSync.sync()
        await loadServerContext()
    }

    /// Verifies credentials against the server before storing them, so a typo
    /// surfaces at the setup screen rather than as an empty library later.
    func signIn(baseURL: URL, username: String, password: String) async throws {
        let candidate = SubsonicClient.Credentials(
            baseURL: baseURL,
            username: username,
            password: password
        )

        await client.configure(candidate)

        do {
            try await client.ping()
        } catch {
            await client.configure(credentials)
            throw error
        }

        Keychain.save(candidate)
        credentials = candidate
        await native.configure(candidate)
        signer = await client.makeSigner()
        artwork.configure(signer: signer)
        phase = .ready

        await loadServerContext()
    }

    func signOut() async {
        Keychain.clear()
        credentials = nil
        signer = nil
        await client.configure(nil)
        await native.configure(nil)
        artwork.configure(signer: nil)
        userState.reset()
        playlistStore.reset()
        queueSync.reset()
        phase = .needsSetup
    }

    /// Radio needs no state of its own; it is a few calls in a known order.
    var radio: RadioBuilder { RadioBuilder(client: client) }

    /// Starts a mix and plays it. Here rather than in a view because three different
    /// screens start radio and none of them should own the sequencing.
    ///
    /// With a `station`, the queue tops itself up as it plays, the way Plexamp's radios do.
    func startRadio(named name: String, songs: [Song], shuffled: Bool = false, station: Station? = nil) {
        guard !songs.isEmpty else { return }
        player.play(songs: songs, startingAt: 0, source: name, shuffled: shuffled, station: station)
    }

    /// Called at launch, on foreground, and on regaining a network. Cheap when the
    /// outbox is empty, which is the normal case.
    func flushOutbox() async {
        guard credentials != nil else { return }
        _ = await outbox.flush(using: client)
    }

    /// Fetch-with-fallback, used by every library screen. Online the server always wins,
    /// because stars and play counts also change from the desktop client; the cache is
    /// only ever consulted when the alternative is an empty screen.
    func cached<T: Codable & Sendable>(
        _ key: String,
        _ fetch: @escaping @Sendable () async throws -> T
    ) async -> T? {
        let (value, isStale) = await cache.value(for: key, fetch: fetch)
        // Only ever raised, never lowered. Home loads four shelves concurrently, so an
        // assignment here meant the last fetch to finish decided the answer for all of
        // them -- one stale shelf among three fresh ones silently cleared the flag.
        // `beginLoadPass()` is what lowers it, once, before a screen starts loading.
        if isStale, value != nil { isShowingCachedData = true }
        return value
    }

    /// Call before a screen begins a round of loads. Resets the staleness flag so it
    /// reflects this pass rather than the last one.
    func beginLoadPass() {
        isShowingCachedData = false
    }

    /// Adopts a queue saved by another client, at its position, **paused**. Resuming
    /// automatically would start music in someone's pocket.
    func adoptRemoteQueue() {
        guard let remote = queueSync.available else { return }
        player.adopt(
            songs: remote.songs,
            currentID: remote.currentID,
            positionSeconds: remote.positionSeconds,
            source: "From \(remote.changedBy)"
        )
        queueSync.dismiss()
    }

    /// Triggers a server rescan. Used after requesting music, because otherwise new
    /// files only appear when Navidrome next scans on its own schedule.
    @discardableResult
    func rescanLibrary() async -> ScanStatus? {
        try? await client.startScan()
    }

    /// Checks whether requested music has landed. Called at launch and on foreground:
    /// acquisition takes minutes to hours, so the useful moments to look are the ones
    /// where the app is coming back anyway.
    func refreshRequests() async {
        guard credentials != nil, requests.isWatchingAnything else { return }
        await requests.refresh()
    }

    /// Best-effort: neither the folder list nor the capability list is worth
    /// blocking the UI on, and both are absent when offline.
    private func loadServerContext() async {
        await client.loadCapabilities()

        // Cached so the scope switcher still exists after a cold launch with no network;
        // without it the control simply vanishes and the app looks single-library.
        let client = self.client
        if let folders: [MusicFolder] = await cached(CacheKey.musicFolders, {
            try await client.musicFolders()
        }) {
            scope.adopt(folders: folders)
        }
    }
}
