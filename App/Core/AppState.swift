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
    /// Since when the music server has answered nothing: set by a request that got no
    /// answer at all, cleared by the next answer to anything. While it is set, whatever has
    /// a saved copy shows it at once instead of waiting out every request's eight seconds
    /// first -- the library screens (`cached`) and the lyrics. Away from home over a link
    /// that reaches nothing, each screen opened was a spinner for eight seconds and then
    /// the copy it could have shown from the start (11-22).
    private(set) var serverSilentSince: Date?
    var isServerSilent: Bool { serverSilentSince != nil }
    /// Counts the server's returns after a silence. Screens that showed saved copies meanwhile
    /// watch it and load again, rather than keeping the saved copy until they are reopened.
    private(set) var serverReturns = 0
    /// No server to be had: no network at all, or one that reaches nothing.
    var isServerUnreachable: Bool { isServerSilent || reachability.network == .offline }

    /// Whether the song plays with no server: downloaded (or its copy in the other library),
    /// or held by the stream cache.
    func isPlayableHere(_ song: Song) -> Bool {
        downloads.localURL(for: song) != nil || streamCache.anyFile(for: song.id) != nil
    }

    /// What is waiting to reach the server, by kind (`ServerOutbox.summary`): the banner and
    /// Settings say so, so nothing done offline looks lost.
    private(set) var waitingToSync: [ServerOutbox.Kind: Int] = [:]
    var waitingToSyncText: String? { ServerOutbox.waitingText(waitingToSync) }

    func refreshWaitingToSync() {
        Task { waitingToSync = await outbox.summary() }
    }

    /// Launch's server work, held because the server answered nothing (`restore`).
    @ObservationIgnored private var launchWaits = false

    let client = SubsonicClient()
    let artwork = ArtworkStore()
    let scope = LibraryScopeStore()
    let userState = UserStateStore()
    let playlistStore = PlaylistStore()
    let playlistArrangement = PlaylistArrangement()
    let requests = MusicRequestService()
    let queueSync = QueueSync()
    /// Carrying the music on from another device (`Handoff`), made with the remote players.
    @ObservationIgnored var handoff: Handoff?
    let playlistSync = PlaylistSync()
    let cache = LibraryCache()
    let playlistArtwork = PlaylistArtwork()
    let history = ListeningHistory()
    let skips = SkipLog()
    let mostPlayed = MostPlayedDownloads()
    let taste = TasteSync()
    let radar = ReleaseRadar()
    let shows = NearbyShows()
    let wordTimings = WordTimingCache()
    /// Lyrics, their translation and word timing, and covers, kept with every download.
    let downloadExtras = DownloadExtras()
    let mixes = DailyMixes()
    let hermes = HermesAsk()
    let recentSearches = RecentSearches()
    let search = SearchService()
    let navigator = Navigator()
    let screenAwake = ScreenAwake()
    let resume = ResumeStore()
    let native = NavidromeClient()
    let downloads = DownloadCenter()
    let downloadFolders = DownloadFolderStore()
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
    let sonic = SonicService()
    /// The player's Song | Video switch and YouTube in search, through the same service.
    let video = VideoService()
    let streamCache = StreamCache()
    let shapes = TrackShapeStore()
    let seekbarLevels = SeekbarLevelsStore()
    let rhythms = RhythmStore()
    /// Shared PCM ring. One buffer for the whole app, because only one thing can be
    /// visualised at a time and it must survive an output switch.
    let spectrumBuffer = AudioSampleBuffer()
    let player = PlaybackController()

    init() {
        // Directories must exist before anything touches disk, and before a
        // background download session can be relaunched into.
        Paths.bootstrap()
        skips.history = history
        userState.configure(client: client, outbox: outbox)
        resume.configure(client: client, outbox: outbox)
        playlistStore.configure(client: client, appState: self)
        requests.configure(client: client)
        hermes.configure(requests: requests)
        hermes.onKeepOffline = { [weak self] id in
            guard let self else { return }
            Task {
                // Hermes may have answered before the list was fetched again.
                if !self.playlistStore.playlists.contains(where: { $0.id == id }) { await self.playlistStore.load() }
                guard let playlist = self.playlistStore.playlists.first(where: { $0.id == id }) else { return }
                self.playlistSync.setIncluded(true, for: playlist)
                await self.playlistSync.sync()
            }
        }
        queueSync.configure(client: client)
        playlistSync.configure(
            client: client, downloads: downloads, reachability: reachability,
            cache: cache, folders: downloadFolders
        )
        downloads.attach(appState: self)
        mostPlayed.attach(self)
        taste.attach(self)
        radar.attach(self)
        shows.attach(self)
        downloadFolders.configure(downloads: downloads, cache: cache)
        autoplay.configure(appState: self)
        guestDJ.configure(appState: self)
        stations.configure(appState: self)
        libraryIndex.configure(appState: self)
        search.configure(appState: self)
        sonic.configure(appState: self)
        video.configure(appState: self)
        // The seekbar's fallback, for a track the sonic service has not analysed.
        seekbarLevels.measured = { [shapes] in shapes.loadedShape(for: $0)?.levels }
        // Asked of the service at whatever address Settings has for it.
        seekbarLevels.fetch = { [sonic] songID in
            let client = SonicClient(configuration: await sonic.configuration)
            return try await client.levels(songID: songID, points: TrackShape.levelPoints)?.levels
        }
        // Beats for beat-matched fades, from the same service.
        rhythms.fetch = { [sonic] songID in
            let client = SonicClient(configuration: await sonic.configuration)
            return try await client.rhythm(songID: songID)
        }
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
            guard let self else { return }
            // What explains a run of timeouts: the phone left Wi-Fi.
            let network = reachability.network
            Task { await Diagnostics.shared.record("network", "now \(network)") }
            player.networkChanged()
            // Whether this network reaches the server, told in seconds, before anything
            // asks and waits out its whole timeout.
            if network != .offline, credentials != nil {
                Task { _ = await self.serverAnswersQuickly() }
            }
        }

        // Plays recorded while offline reach the server the moment there is one.
        reachability.onCameOnline = { [weak self] in
            Task { await self?.flushOutbox() }
        }

        // Intents cannot be injected into, so the running app is published here for
        // them to find. Set last, once everything above is wired.
        MusicIntentBridge.appState = self

        // Lyrics for what the stream cache takes, as for downloads.
        streamCache.onSongCached = { [weak self] song in self?.downloadExtras.keepCached(song) }
        // Queue uploads wait while the server answers nothing; `catchUp` sends the queue.
        queueSync.isHeld = { [weak self] in self?.isServerSilent ?? false }

        // Any answer after saved copies went up means the server is there again.
        let client = client
        Task {
            await client.setOnAnswer { [weak self] sent in
                guard let self else { return }
                Task { @MainActor in self.serverAnswered(sentAt: sent) }
            }
            await client.setOnSilence { [weak self] in
                Task { @MainActor in self?.serverWentSilent() }
            }
            await outbox.setOnChange { [weak self] in
                Task { @MainActor in self?.refreshWaitingToSync() }
            }
            self.refreshWaitingToSync()
        }
        downloadExtras.attach(self)

        Task { await restore() }
    }

    /// Restores a saved session on launch. A stored credential is trusted without a
    /// round trip, so the app reaches `.ready` with no network at all -- which is
    /// what lets downloaded music play offline from a cold launch.
    func restore() async {
        guard let saved = Keychain.loadCredentials() else {
            #if targetEnvironment(simulator)
            if await signInFromLaunchEnvironment() { return }
            #endif
            phase = .needsSetup
            return
        }

        credentials = saved
        await client.configure(saved)
        await native.configure(saved)
        signer = await client.makeSigner()
        artwork.configure(signer: signer)
        downloads.resumeWaiting()
        phase = .ready
        // Whether the server answers, asked at once: screens opened from three seconds on show
        // their saved copies straight away when it doesn't.
        async let answers = serverAnswersQuickly()
        // Once a day, and not in the launch's own rush of requests.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20 * 1_000_000_000)
            await self?.mostPlayed.refresh()
        }

        // Before the queue is rebuilt, so the restored track is found in Downloads. A
        // few milliseconds of disk; without it, launch raced the catalog and lost.
        await downloads.catalogLoaded()
        // Before any sync: files a lost catalog left behind come back as downloads.
        await downloads.readoptUntracked()
        await player.restore()
        // A server answering nothing held each of these for a request's whole timeout, one
        // after another. They wait for it instead (`serverAnswered`), and the saved copies
        // show meanwhile.
        guard await answers else {
            launchWaits = true
            return
        }
        await finishLaunch()
    }

    private func finishLaunch() async {
        await sonic.refreshStatus(force: true)
        await flushOutbox()
        await refreshRequests()

        // Both are cheap when there is nothing to do, and both want to happen once the
        // credentials are known rather than at construction.
        await resume.refresh()
        handoff?.look()
        await playlistSync.sync()
        await loadServerContext()
    }

    /// Back in the foreground (the phone), or the window shown again (the desktop): what is
    /// owed, and what moved on meanwhile. One quick question first, as at launch: while the
    /// server answers nothing, it all waits for it to answer. Before, every return to the
    /// app sent about ten requests that each waited out eight seconds on a link that reached
    /// nothing (11-22).
    func cameBack() {
        guard phase == .ready else { return }
        Task {
            guard await serverAnswersQuickly() else { return }
            catchUp()
        }
    }

    /// The overnight run (`OvernightSync` on the phone): everything the app catches up on
    /// while it is open, and every download's extras filled in, waited for so iOS keeps the
    /// app awake for it. False when there was no server, or the time ran out.
    func overnightSync() async -> Bool {
        guard credentials != nil else { return false }
        await Diagnostics.shared.record("app", "overnight sync: started")
        guard await serverAnswersQuickly() else {
            await Diagnostics.shared.record("app", "overnight sync: the server isn't answering")
            return false
        }
        await flushOutbox()
        await playlistSync.sync()
        await mostPlayed.refresh()
        downloads.resumeWaiting()
        downloadExtras.sweep(force: true)
        let finished = await downloadExtras.idle()
        await Diagnostics.shared.record("app", "overnight sync: \(finished ? "done" : "stopped before the end")"
            + ", \(downloads.activeCount) downloads still arriving")
        return finished
    }

    /// Whether the server answers within a few seconds. When it doesn't, it is silent from
    /// now (`serverSilentSince`): saved copies show at once, and what waits on it waits.
    func serverAnswersQuickly() async -> Bool {
        do {
            try await client.ping(timeout: 3)
            return true
        } catch {
            return false
        }
    }

    /// What `cameBack` and the end of a silence bring up to date.
    private func catchUp() {
        Task { await flushOutbox() }
        Task { await refreshRequests() }
        Task { await sonic.refreshStatus() }
        Task { await playlistSync.sync() }
        downloads.resumeWaiting()
        Task { await mostPlayed.refresh() }
        Task { await playlistStore.refreshIfStale() }
        // The queue as it is now, which waited (`QueueSync.isHeld`).
        queueSync.pushNow(queue: player.queue, elapsed: player.elapsed)
        // Nothing playing here: catch up with wherever the music is, so a press of play
        // carries on from it.
        handoff?.look()
    }

    #if targetEnvironment(simulator)
    /// Simulator only (the macOS build VM): signs in from the launch environment, so a
    /// fresh simulator can be tested without typing on the setup screen. `simctl launch`
    /// passes variables prefixed `SIMCTL_CHILD_`, so the caller sets
    /// `SIMCTL_CHILD_MUSIC_SERVER`, `_MUSIC_USER` and `_MUSIC_PASSWORD`; the values live on
    /// the build machine, never in the repo. They take the same path as the setup screen
    /// (ping first, then the Keychain). None of this exists in a device build.
    private func signInFromLaunchEnvironment() async -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard let server = environment["MUSIC_SERVER"], let baseURL = URL(string: server),
              let username = environment["MUSIC_USER"], !username.isEmpty,
              let password = environment["MUSIC_PASSWORD"], !password.isEmpty
        else { return false }
        do {
            try await signIn(baseURL: baseURL, username: username, password: password)
            return true
        } catch {
            return false
        }
    }
    #endif

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
        downloads.resumeWaiting()
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
    var radio: RadioBuilder { RadioBuilder(client: client, native: native) }

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
        // Sent once it answers (`catchUp`): each kind would wait out its timeout first.
        guard credentials != nil, !isServerSilent else { return }
        // What downloads still lack -- lyrics, a translation, covers -- once there is a
        // server to ask; returns at once, as it runs on its own.
        downloadExtras.sweep()
        let hadPlaylistEdits = await outbox.hasPlaylistEdits()
        _ = await outbox.flush(using: client)
        // Playlist edits made offline, now on the server: the lists and downloads follow.
        if hadPlaylistEdits {
            await playlistStore.load()
            playlistSync.syncSoon()
        }
        await flushUnsentLogs()
        await taste.sync()
        // After the sync, which may bring in other devices' plays under old ids too.
        await HistoryRepair.runIfDue(self)
    }

    /// Fetch-with-fallback, used by every library screen. Online the server always wins,
    /// because stars and play counts also change from the desktop client; the cache is
    /// only ever consulted when the alternative is an empty screen.
    func cached<T: Codable & Sendable>(
        _ key: String,
        _ fetch: @escaping @Sendable () async throws -> T
    ) async -> T? {
        // The server answering nothing: the saved copy at once, and the server asked all the
        // same, behind it, so the next look is fresh and an answer ends the silence.
        if isServerSilent, let saved = await cache.load(T.self, for: key) {
            let cache = cache
            Task.detached(priority: .utility) { _ = await cache.value(for: key, fetch: fetch) }
            isShowingCachedData = true
            cachedDataSince = .now
            return saved
        }
        let (value, isStale) = await cache.value(for: key, fetch: fetch)
        // Only ever raised here, never lowered. Home loads four shelves concurrently, so
        // an assignment here meant the last fetch to finish decided the answer for all of
        // them -- one stale shelf among three fresh ones silently cleared the flag.
        // `beginLoadPass()` lowers it before a screen starts loading, and `serverAnswered`
        // once the server answers something asked after this.
        if isStale, value != nil {
            isShowingCachedData = true
            cachedDataSince = .now
        }
        return value
    }

    /// When `isShowingCachedData` was last raised.
    @ObservationIgnored private var cachedDataSince: Date?

    /// The server answered a request sent at `sent`. Sent after the saved copies went up,
    /// it means the server is there again, and the app stops saying otherwise. Before,
    /// only a few screens' reloads lowered it, never Search's, which said "Offline" over
    /// results that had just come from the server (2026-11-08).
    func serverAnswered(sentAt sent: Date) {
        if let silent = serverSilentSince {
            serverSilentSince = nil
            let quiet = Diagnostics.duration(Date.now.timeIntervalSince(silent))
            Task { await Diagnostics.shared.record("network", "the server answers again, after \(quiet) without") }
            downloadExtras.serverAnswered()
            autoplay.serverChanged()
            serverReturns += 1
            if launchWaits {
                launchWaits = false
                Task { await finishLaunch() }
            } else {
                catchUp()
            }
        }
        guard isShowingCachedData, let since = cachedDataSince, sent > since else { return }
        isShowingCachedData = false
    }

    private func serverWentSilent() {
        guard serverSilentSince == nil else { return }
        serverSilentSince = .now
        Task { await Diagnostics.shared.record("network", "the server isn't answering: saved copies first until it does") }
        probeWhileSilent()
        player.serverWentSilent()
        autoplay.serverChanged()
    }

    /// The smallest request there is, now and then while the server answers nothing: what
    /// waits on it ("Can't reach the music server" over the lyrics) comes back by itself
    /// when it does. It used to wait for something else to happen to ask -- a song change,
    /// coming back to the foreground -- and a paused screen could say "can't reach" for good.
    private func probeWhileSilent() {
        guard silenceProbe == nil else { return }
        silenceProbe = Task { [weak self] in
            var wait: Double = 15
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(wait))
                guard let self, self.isServerSilent else { break }
                try? await self.client.ping()
                wait = min(wait * 2, 60)
            }
            self?.silenceProbe = nil
        }
    }

    @ObservationIgnored private var silenceProbe: Task<Void, Never>?

    /// Call before a screen begins a round of loads. Resets the staleness flag so it
    /// reflects this pass rather than the last one.
    func beginLoadPass() {
        isShowingCachedData = false
    }

    /// Lyrics timed by hand, saved into the song's file on the server through the sonic
    /// service, and into the copy kept with a download. Returns the lyrics as saved, for
    /// the screen to show at once: Navidrome serves them once its watcher has scanned the
    /// folder again, a few seconds later.
    func saveLyrics(_ timing: LyricsTiming, from lyrics: StructuredLyrics, songID: String) async throws -> StructuredLyrics {
        let signIn = try sonicSignIn()
        try await SonicClient(configuration: sonic.configuration).saveLyrics(songID: songID, timing: timing, signIn: signIn)
        let saved = timing.saved(from: lyrics)
        await LyricsStore.shared.replace(lyrics, with: saved, for: songID)
        await Diagnostics.shared.record("lyrics", "saved \(timing.lines.count) timed lines into \(songID)")
        return saved
    }

    /// LRCLIB's lyrics for a song with none, saved beside it on the server by the sonic
    /// service, and with the download when the song is one.
    func findLyrics(songID: String) async throws -> SonicClient.FoundLyrics {
        let signIn = try sonicSignIn()
        let answer = try await SonicClient(configuration: sonic.configuration).findLyrics(songID: songID, signIn: signIn)
        switch answer {
        case let .found(lyrics):
            if downloads.isDownloaded(songID) { await LyricsStore.shared.save([lyrics], for: songID) }
            await Diagnostics.shared.record("lyrics", "found \(lyrics.lines.count) lines for \(songID) on LRCLIB")
        case .notFound:
            await Diagnostics.shared.record("lyrics", "none on LRCLIB for \(songID)")
        case .instrumental:
            await Diagnostics.shared.record("lyrics", "LRCLIB has \(songID) as instrumental")
        }
        return answer
    }

    /// The Subsonic sign-in, for the sonic service to check with Navidrome.
    private func sonicSignIn() throws -> SonicClient.SignIn {
        guard let credentials else { throw LyricsSaveError(message: "Sign in to the server first.") }
        let salt = SubsonicAuth.makeSalt()
        return SonicClient.SignIn(
            u: credentials.username,
            t: SubsonicAuth.token(password: credentials.password, salt: salt),
            s: salt
        )
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
