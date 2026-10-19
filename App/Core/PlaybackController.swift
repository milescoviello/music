import Foundation
import Observation
#if canImport(UIKit)
import AVFoundation
import MediaPlayer
import UIKit
#endif

/// Everything the UI talks to for playback.
///
/// Owns the queue, the play tracker, the lock screen and persistence, and makes the
/// decisions about sound — which chain a track gets, whether a transition fades. It does
/// **not** produce the sound: that is `QueuePlayerOutput`, which executes those decisions.
///
/// `@MainActor` rather than an actor: `AVQueuePlayer`, `MPNowPlayingInfoCenter` and
/// `UIImage` are all main-thread-affine and
/// non-`Sendable`, so actor isolation would mean an unsafe opt-out plus a hop on every
/// remote command and time tick.
@MainActor
@Observable
final class PlaybackController {
    // MARK: - Observable state

    private(set) var queue = PlaybackQueue() {
        didSet { queueDidChange() }
    }
    private(set) var isPlaying = false
    private(set) var isBuffering = false
    /// Seconds. Read by the in-app scrubber at 4 Hz.
    private(set) var elapsed: Double = 0
    /// Set when playback started somewhere other than the beginning because a resume
    /// position was known. Drives the "Resumed from 42:10 · Start over" strip, which is
    /// the whole difference between a helpful resume and a baffling one.
    var resumeNotice: ResumeNotice?

    struct ResumeNotice: Equatable, Sendable {
        let songID: String
        let seconds: Double
    }
    private(set) var duration: Double = 0

    // What most views want from the queue, each kept apart from it and assigned only
    // when it changes. Read through `queue`, every Guest DJ pick, Autoplay or station
    // top-up and Play Next redrew everything that only wanted to know what is playing:
    // every song row on screen (to tint the current one), every album card's menu, the
    // mini player, the player itself, and every list's bottom clearance.

    /// The track playing.
    private(set) var currentSong: Song?
    private(set) var hasQueue = false
    /// Whether Add to Up Next is on offer: something added is still to come.
    private(set) var canAddToUpNext = false

    private func queueDidChange() {
        let current = queue.current
        if current != currentSong { currentSong = current }
        if hasQueue == queue.isEmpty { hasQueue = !queue.isEmpty }
        let canAdd = queue.canAddToUpNext
        if canAdd != canAddToUpNext { canAddToUpNext = canAdd }
    }

    // MARK: - Dependencies

    private let output = QueuePlayerOutput()

    private let session = AudioSessionCoordinator()
    private let nowPlaying = NowPlayingCenter()
    private let store = PlaybackQueueStore(directory: Paths.root, legacyURL: Paths.queue)
    private let tracker = PlayTracker()
    private weak var appState: AppState?

    private var saveTask: Task<Void, Never>?
    /// The visualiser's PCM ring, handed to the output before anything plays.
    private var spectrumSink: AudioSampleBuffer?
    /// When the local queue was last written to disk, so `QueueSync` can tell whether a
    /// remote queue is genuinely newer.
    private(set) var lastSavedAt: Date?

    /// Set once Autoplay has been asked to extend the queue for the track ending now, so
    /// the 4 Hz tick asks once rather than every quarter second.
    private var autoplayRequested = false

    /// Current + 2 upcoming. Preloading the next item is what makes the boundary
    /// gapless; inserting a 292-track playlist would be a connection stampede.
    private let windowSize = 3

    init() {
        session.configure()

        session.onPause = { [weak self] in self?.pause() }
        session.onResume = { [weak self] in self?.play() }

        nowPlaying.onPlay = { [weak self] in self?.play() }
        nowPlaying.onPause = { [weak self] in self?.pause() }
        nowPlaying.onToggle = { [weak self] in self?.togglePlayPause() }
        nowPlaying.onNext = { [weak self] in self?.next() }
        nowPlaying.onPrevious = { [weak self] in self?.previous() }
        nowPlaying.onSeek = { [weak self] time in self?.seek(to: time) }

        // Fire-and-forget both ways. A lost "now playing" is cosmetic, and a lost
        // play count is what the durable outbox exists to prevent later; neither is
        // worth blocking or failing playback over.
        tracker.onNowPlaying = { [weak self] event in
            self?.report(event, submission: false)
        }
        tracker.onPlayCounted = { [weak self] event in
            self?.report(event, submission: true)
        }

        output.onAdvanced = { [weak self] songID in
            self?.handleAdvanced(to: songID)
        }
        output.onTick = { [weak self] elapsed, isMoving in
            self?.tick(elapsed: elapsed, isMoving: isMoving)
        }
    }

    func attach(appState: AppState) {
        self.appState = appState

        output.locate = { [weak self] song in self?.locate(song) }
        // A chain per track: its own ReplayGain, the shared EQ and limiter.
        let dsp = appState.audio.dsp
        output.makeChain = { song in DSPChain(replayGain: song.replayGain, settings: dsp) }
        output.transition = { [weak self] from, to in
            self?.transitionOverlap(from: from, to: to)
        }
        output.beatMatch = { [weak self] from, to, overlap in
            self?.beatMatch(from: from, to: to, overlap: overlap)
        }

        // A mix that is playing keeps growing, so the queue never runs out mid-listen.
        appState.mixes.onExtended = { [weak self] mix, added in
            guard let self, queue.sourceDescription == mix.title, !added.isEmpty else { return }
            append(added)
        }

        // The sample feed goes in **now**, before anything plays, rather than when the
        // visualiser first opens: every item's tap is built with it, so opening the
        // visualiser is never a change to a running audio graph, which is audible. The
        // cost of feeding it unseen is one `memcpy` per buffer; the FFT only runs while
        // a visualiser is on screen.
        spectrumSink = appState.spectrumBuffer
        output.setSpectrumSink(spectrumSink)

        // A cached file replaces the stream for any item that has not started, and is
        // measured so the fades either side of it stop being guesses -- if it is about to
        // play. Cache-ahead fetches up to fifteen tracks, and decoding every one of them in
        // full as it landed kept the CPU busy for minutes after a queue started; the rest
        // are measured when they reach the window.
        appState.streamCache.onCached = { [weak self] songID, _ in
            guard let self else { return }
            if let song = currentWindow.first(where: { $0.id == songID }) {
                measureLocal([song])
            }
            output.sourceChanged(for: songID)
        }
        appState.shapes.onMeasured = { [weak self] songID in
            guard let self, currentWindow.contains(where: { $0.id == songID }) else { return }
            output.refreshTransitions()
        }
        // A track skipped past while it waited to be decoded is not decoded.
        appState.shapes.isWanted = { [weak self] songID in
            self?.currentWindow.contains(where: { $0.id == songID }) ?? false
        }
    }

    /// Sweet Fades' rule for one transition: seconds of crossfade, or nil for gapless.
    ///
    /// Never within an album played in order — the gap between two album tracks is the
    /// artist's — and never with the setting off. Everything else fades.
    ///
    /// Measured when both tracks are on the phone, which with cache-ahead is nearly
    /// always; the fallback overlap only for a pair where one is still streaming.
    private func transitionOverlap(from current: Song, to next: Song) -> Double? {
        guard let appState else { return nil }
        return TransitionPlanner.overlap(
            from: current,
            to: next,
            sweetFades: appState.audio.sweetFades,
            // A file's own measurement first; for a track that is only streaming, the sonic
            // service's loudness readings of it.
            outgoing: appState.shapes.shape(for: current.id) ?? appState.sonic.shape(for: current.id),
            incoming: appState.shapes.shape(for: next.id) ?? appState.sonic.shape(for: next.id)
        )
    }

    /// A beat-matched start for a fade Sweet Fades has already decided on, when the setting
    /// is on and both tracks' beats are here and steady enough; nil leaves the fade as it is.
    ///
    /// Only for tracks playing from their stored files. The beats were measured on those,
    /// and a server conversion to MP3 can begin with tens of milliseconds of encoder delay
    /// that the stored file does not have — enough to put every beat audibly off.
    private func beatMatch(from current: Song, to next: Song, overlap: Double) -> BeatMatch.Plan? {
        guard let appState, appState.audio.beatMatchedFades,
              playsStoredFile(current), playsStoredFile(next),
              let outgoing = appState.rhythms.rhythm(for: current.id),
              let incoming = appState.rhythms.rhythm(for: next.id)
        else { return nil }
        return BeatMatch.plan(outgoing: outgoing, incoming: incoming, overlap: overlap)
    }

    /// Whether `locate` plays a song from its stored file — downloaded, cached or streamed as
    /// the original — rather than from a server conversion. The same order `locate` takes.
    private func playsStoredFile(_ song: Song) -> Bool {
        guard let appState, !Self.needsTranscode(song.suffix) else { return false }
        let network = appState.reachability.network
        let policy = appState.streaming.policy
        let cache = appState.streamCache

        if appState.downloads.localURL(for: song.id) != nil, policy.usesDownload(on: network) {
            return appState.downloads.catalog.entries[song.id]?.quality == .original
        }
        let variant = policy.variant(for: song, on: network)
        if network == .offline || cache.file(for: song.id, satisfying: variant) != nil {
            return cache.file(for: song.id, satisfying: .original) != nil
        }
        return variant == .original
    }

    /// Fetches the beats of what is playing and what is next while Beat-Matched Fades is on,
    /// so a matched fade is planned well before it is due.
    private func requestRhythms(_ songs: [Song]) {
        guard let appState, appState.audio.sweetFades, appState.audio.beatMatchedFades,
              appState.reachability.network != .offline
        else { return }
        appState.rhythms.request(songs.map(\.id)) { [weak self] songID in
            guard let self, currentWindow.contains(where: { $0.id == songID }) else { return }
            output.refreshTransitions()
        }
    }

    /// Where a song's bytes are, in Plexamp's order: a download (if the setting prefers
    /// it on this network), then a cached copy at least as good as what this network
    /// asks for, then the stream itself.
    private func locate(_ song: Song) -> MediaLocation? {
        guard let appState else { return nil }
        let network = appState.reachability.network
        let policy = appState.streaming.policy
        let download = appState.downloads.localURL(for: song.id)

        if let download, policy.usesDownload(on: network) {
            return MediaLocation(url: download, mimeType: nil, isLocal: true)
        }

        let variant = policy.variant(for: song, on: network)
        if let cached = appState.streamCache.file(for: song.id, satisfying: variant) {
            return MediaLocation(url: cached, mimeType: nil, isLocal: true)
        }

        // No network: whatever copy is here, at whatever quality, beats silence.
        if network == .offline,
           let local = download ?? appState.streamCache.anyFile(for: song.id) {
            return MediaLocation(url: local, mimeType: nil, isLocal: true)
        }

        // AVFoundation has no Vorbis or Opus decoder, so those are always converted —
        // `variant` sees to it. Verified: `format=mp3` returns `audio/mpeg`, but
        // **chunked with no Content-Length**, so seeking a converted stream is unreliable
        // until the cache has the whole file.
        guard let signer = appState.signer,
              let url = signer.url("stream.view", StreamingPolicy.streamQuery(for: song, variant: variant))
        else { return nil }

        let mimeType = variant == .original
            ? song.contentType ?? Self.mimeType(for: song.suffix)
            : "audio/mpeg"
        return MediaLocation(url: url, mimeType: mimeType, isLocal: false)
    }

    /// Where the cache fetches a variant from. The original comes from `download.view`
    /// — the stored file, with a length — like a download does.
    private static func cacheURL(for song: Song, variant: StreamVariant, signer: SubsonicSigner) -> URL? {
        switch variant {
        case .original:
            return signer.url("download.view", ["id": song.id])
        case .mp3:
            return signer.url("stream.view", StreamingPolicy.streamQuery(for: song, variant: variant))
        }
    }

    // MARK: - Cache ahead

    /// Tells the stream cache what will be needed: the next tracks, as far ahead as this
    /// network's setting allows, at this network's quality.
    ///
    /// The current track is included on Wi-Fi only. It is already streaming, so caching
    /// it costs its bytes twice — nothing at home, real money on cellular — and buys a
    /// measured fade out of it and a copy for next time.
    private func planCache() {
        guard let appState else { return }
        let network = appState.reachability.network
        let policy = appState.streaming.policy
        let cache = appState.streamCache
        cache.maxBytes = policy.cacheBytes

        let window = currentWindow
        // The seekbar's shapes for what is playing and what is next, so a track's is
        // there when it starts. From the service, which has them whether or not the
        // track is cached.
        if network != .offline, appState.playerSettings.seekbarStyle != .line {
            appState.seekbarLevels.request(window.map(\.id))
        }
        requestRhythms(window)
        guard network != .offline, let signer = appState.signer, let current = window.first else {
            cache.pause()
            measureLocal(window)
            return
        }

        let ahead = queue.repeatMode == .one ? [] : queue.upcoming(policy.tracksAhead(on: network))
        let wanted = (network == .wifi ? [current] : []) + ahead

        var requests: [StreamCache.Request] = []
        for song in wanted {
            if appState.downloads.localURL(for: song.id) != nil, policy.usesDownload(on: network) { continue }
            let variant = policy.variant(for: song, on: network)
            guard let url = Self.cacheURL(for: song, variant: variant, signer: signer) else { continue }
            requests.append(StreamCache.Request(song: song, variant: variant, url: url))
        }
        cache.prefetch(requests)
        measureLocal(window)
    }

    /// Gets the window's tracks measured, so their transitions can be planned. Cached
    /// arrivals in the window are measured as they land.
    ///
    /// The sonic service first, for every track, on the phone or not: it has the same
    /// readings for nearly the whole library, and one request is far cheaper than decoding
    /// a whole track here, which is seconds of CPU per track. A file on the phone is
    /// decoded only when the service cannot give its shape -- not analysed yet, or not
    /// reachable.
    private func measureLocal(_ songs: [Song]) {
        guard let appState else { return }
        // Measured here already, by an earlier decode.
        let unmeasured = songs.filter { appState.shapes.shape(for: $0.id)?.levels == nil }
        appState.sonic.prefetchShapes(for: unmeasured) { [weak self] songID in
            guard let self, currentWindow.contains(where: { $0.id == songID }) else { return }
            output.refreshTransitions()
        } onMissing: { [weak self] songID in
            guard let self, let appState = self.appState,
                  currentWindow.contains(where: { $0.id == songID }),
                  let file = appState.downloads.localURL(for: songID)
                      ?? appState.streamCache.anyFile(for: songID)
            else { return }
            appState.shapes.measure(songID: songID, at: file)
        }
    }

    /// The network changed, so does what to cache and at what quality. Items already
    /// built play on as they are.
    func networkChanged() {
        planCache()
    }

    func streamingSettingsChanged() {
        planCache()
    }

    /// Replaces the queue with one from another device, paused at its position.
    func adopt(songs: [Song], currentID: String?, positionSeconds: Double, source: String) {
        guard !songs.isEmpty else { return }
        let index = currentID.flatMap { id in songs.firstIndex { $0.id == id } } ?? 0

        queue = .make(
            tracks: songs,
            startingAt: index,
            shuffled: false,
            source: source,
            repeatMode: queue.repeatMode
        )
        appState?.guestDJ.queueReplaced()
        rebuildOutput(startPlaying: false, seekTo: positionSeconds)
        persistNow()
    }

    // MARK: - Visualiser

    /// There is deliberately no `stopSpectrum`, and no work here on the common path: the
    /// feed is set in `attach(appState:)` before any audio exists. This only covers an
    /// output built before that ran, and is a no-op otherwise — a second sink is ignored.
    func startSpectrum() {
        guard let appState else { return }
        spectrumSink = appState.spectrumBuffer
        output.setSpectrumSink(spectrumSink)
    }

    /// Sweet Fades or Beat-Matched Fades was switched, so every planned transition is
    /// re-asked — and the beats it needs fetched, if it now needs them. The EQ and leveling
    /// need nothing here: the tap of whatever is playing reads them live.
    func transitionSettingsChanged() {
        requestRhythms(currentWindow)
        output.refreshTransitions()
    }

    // MARK: - Starting playback

    /// `startAt` is seconds into the first track — for "play from this lyric", and for
    /// resuming a long track where it was left. Passed into the rebuild rather than
    /// seeking afterwards, which would race the output coming up.
    func play(
        songs: [Song],
        startingAt index: Int,
        source: String,
        shuffled: Bool = false,
        startAt seconds: Double = 0,
        station: Station? = nil
    ) {
        guard !songs.isEmpty else { return }

        queue = .make(
            tracks: songs,
            startingAt: index,
            shuffled: shuffled,
            source: source,
            repeatMode: queue.repeatMode,
            station: station
        )
        appState?.guestDJ.queueReplaced()
        if let appState {
            appState.recentPlays.record(PlayOrigin.infer(
                songs: songs, source: source, station: station, playlists: appState.playlistStore.playlists
            ))
        }

        // A saved position only applies when the caller did not ask for one, and only to
        // tracks long enough for it to matter -- `ResumeStore` decides both.
        var startSeconds = seconds
        if seconds == 0, let current = queue.current,
           let resume = appState?.resume.resumePoint(for: current) {
            startSeconds = resume
            resumeNotice = ResumeNotice(songID: current.id, seconds: resume)
        } else {
            resumeNotice = nil
        }

        rebuildOutput(startPlaying: true, seekTo: startSeconds)

        if appState?.playerSettings.opensPlayerOnPlay == true {
            appState?.navigator.showsPlayer = true
        }
    }

    /// Discards the resume position and starts the current track again.
    func startOver() {
        if let song = queue.current { appState?.resume.clear(songID: song.id) }
        resumeNotice = nil
        seek(to: 0)
    }

    func playNext(_ songs: [Song]) {
        guard !songs.isEmpty else { return }
        if queue.isEmpty {
            play(songs: songs, startingAt: 0, source: "Queue")
            return
        }
        queue.insertNext(songs)
        refillWindow()
        persist()
    }

    /// Plexamp's Add to Queue: the very end.
    func append(_ songs: [Song]) {
        guard !songs.isEmpty else { return }
        if queue.isEmpty {
            play(songs: songs, startingAt: 0, source: "Queue")
            return
        }
        queue.append(songs)
        refillWindow()
        persist()
    }

    /// Plexamp's Add to Up Next: after whatever was added last, so additions play in the
    /// order they were made. Offered only once something has been added.
    func addToUpNext(_ songs: [Song]) {
        guard !songs.isEmpty else { return }
        if queue.isEmpty {
            play(songs: songs, startingAt: 0, source: "Queue")
            return
        }
        queue.addToUpNext(songs)
        refillWindow()
        persist()
    }

    /// Plexamp's Clear Play Queue: everything but the track playing, which plays on.
    func clearQueue() {
        queue.clearAllButCurrent()
        refillWindow()
        persist()
    }

    // MARK: - Transport

    func play() {
        guard hasQueue else { return }
        session.activate()
        output.play()
        isPlaying = true
        session.noteIsPlaying(true)
        publishNowPlaying(force: true)
        persist()
    }

    func pause() {
        output.pause()
        isPlaying = false
        tracker.interrupted(at: elapsed)
        // Pausing is when someone walks away, which is exactly what a resume position is
        // for. Track changes and finishing are handled where they happen.
        appState?.resume.note(song: queue.current, elapsed: elapsed)
        session.noteIsPlaying(false)
        publishNowPlaying(force: true)
        persist()
    }

    /// The app came back to the foreground.
    ///
    /// Only ever resumes music that an interruption paused, and only when nothing else is
    /// using the speaker — the coordinator holds both conditions.
    func appBecameActive() {
        session.resumeIfInterruptionWentUnreported()
    }

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    /// Used by the sleep timer. Restores the volume afterwards, so the next manual
    /// play is not silent -- the single most likely bug in a fade implementation.
    func fadeOutAndPause(over duration: Double = 6) {
        guard isPlaying else { return }

        Task { [weak self] in
            let steps = 30
            for step in 1...steps {
                guard let self, isPlaying else { return }
                output.volume = Float(1 - Double(step) / Double(steps))
                try? await Task.sleep(for: .seconds(duration / Double(steps)))
            }
            guard let self else { return }
            pause()
            output.volume = 1
        }
    }

    func next() {
        guard queue.advance() else {
            pause()
            return
        }
        rebuildOutput(startPlaying: isPlaying, seekTo: 0)
    }

    /// Rewinds first, the way every native player does, and only then goes back.
    func previous() {
        if elapsed > 3 {
            seek(to: 0)
            return
        }
        guard queue.rewind() else {
            seek(to: 0)
            return
        }
        rebuildOutput(startPlaying: isPlaying, seekTo: 0)
    }

    /// Playback speed, pitch preserved. Plexamp's 0.5–2× in tenths; not remembered
    /// across launches, so a sped-up podcast never surprises the next album.
    private(set) var speed: Float = 1

    static let speedRange: ClosedRange<Float> = 0.5...2

    func setSpeed(_ value: Float) {
        let stepped = (min(max(value, Self.speedRange.lowerBound), Self.speedRange.upperBound) * 10).rounded() / 10
        speed = stepped
        output.rate = stepped
        publishNowPlaying(force: true)
    }

    /// Plexamp's quick skip: a relative seek within the track, clamped to it.
    func skip(by seconds: Double) {
        let target = elapsed + seconds
        if duration > 0, target >= duration - 1 {
            next()
            return
        }
        seek(to: max(0, target))
    }

    func seek(to seconds: Double) {
        output.seek(to: seconds)
        elapsed = seconds
        tracker.interrupted(at: seconds)
        publishNowPlaying(force: true)
    }

    func jump(toOrderIndex index: Int) {
        queue.jump(toOrderIndex: index)
        rebuildOutput(startPlaying: true, seekTo: 0)
    }

    func removeFromQueue(orderIndex index: Int) {
        let wasCurrent = index == queue.position
        queue.remove(atOrderIndex: index)

        if wasCurrent {
            rebuildOutput(startPlaying: isPlaying, seekTo: 0)
        } else {
            refillWindow()
            persist()
        }
    }

    func moveInQueue(from source: Int, to destination: Int) {
        queue.move(fromOrderIndex: source, toOrderIndex: destination)
        refillWindow()
        persist()
    }

    func toggleShuffle() {
        if queue.isShuffled {
            queue.unshuffle()
        } else {
            queue.shuffle(keepingCurrent: true)
        }
        refillWindow()
        persist()
    }

    func cycleRepeat() {
        queue.repeatMode = queue.repeatMode.next
        // Repeat-one changes the window itself -- see `currentWindow`.
        refillWindow()
        persist()
    }

    // MARK: - Scrobbling

    private func report(_ event: PlayTracker.Event, submission: Bool) {
        // Listening is the other trigger for more mixes, alongside scrolling to the end of
        // the shelf. Cheap: it does nothing once the shelf is deep enough for one session.
        if submission, let appState {
            appState.mixes.topUpWhileListening(appState: appState, scope: appState.scope.scope)
        }

        guard let appState else { return }

        if submission, let song = queue.current, song.id == event.songID {
            // Recorded here rather than in the tracker so the local history and the
            // server's counts are written from the same decision -- they can differ in
            // reach, but never in whether a play happened.
            appState.history.record(song, at: event.listenedAt)
        }

        guard submission else {
            // "Now playing" is ephemeral -- it expires on the server in minutes, so
            // queueing a stale one would be worse than losing it.
            Task { try? await appState.client.scrobble(id: event.songID, submission: false) }
            return
        }

        Task {
            do {
                try await appState.client.scrobble(
                    id: event.songID, submission: true, at: event.listenedAt
                )
            } catch {
                // Offline, or the server is down. The play is owed either way, so it
                // goes to disk with the time it actually happened.
                await appState.outbox.enqueue(
                    songID: event.songID, listenedAt: event.listenedAt
                )
            }
        }
    }

    // MARK: - Output

    /// Current track plus the preload window. Three items: preloading the next is what
    /// makes an album boundary gapless, and inserting a 292-track playlist would be a
    /// connection stampede.
    ///
    /// Just the current track on repeat-one, so the output runs out at its end and the
    /// queue — which stays put — reloads it. Preloading the next track there meant the
    /// player moved on to it and the old repeat handling then rewound *that* song,
    /// while the queue still said the first one was playing.
    private var currentWindow: [Song] {
        guard let current = queue.current else { return [] }
        guard queue.repeatMode != .one else { return [current] }
        return [current] + queue.upcoming(windowSize - 1)
    }

    private func rebuildOutput(startPlaying: Bool, seekTo seconds: Double) {
        let window = currentWindow

        guard let current = window.first else {
            output.stop()
            isPlaying = false
            appState?.streamCache.pause()
            return
        }

        output.load(window: window, startAt: seconds)
        queueChanged()

        duration = Double(current.duration ?? 0)
        elapsed = seconds
        tracker.trackChanged(to: current, duration: duration)
        tracker.interrupted(at: seconds)

        if startPlaying {
            play()
        } else {
            publishNowPlaying(force: true)
        }
    }

    /// Asks the mix that is playing for more tracks before the queue runs out.
    ///
    /// Five tracks of headroom: enough that the extension's requests finish long before
    /// the music would have stopped, and late enough that a quick listen does not drag
    /// down a pile of tracks nobody will hear.
    private func topUpMixQueue() {
        guard let appState else { return }
        let remaining = queue.order.count - (queue.position + 1)
        guard remaining <= 5,
              let mix = appState.mixes.mixes.first(where: {
                  $0.title == queue.sourceDescription && $0.isExhausted != true
              })
        else { return }

        appState.mixes.extend(
            mixID: mix.id, appState: appState, scope: appState.scope.scope
        )
    }

    /// Keeps the preload window topped up without disturbing what is playing.
    private func refillWindow() {
        output.updateUpcoming(Array(currentWindow.dropFirst()))
        queueChanged()
    }

    /// Everything that follows the queue: the cache ahead, Autoplay's carousel, and the
    /// Guest DJ. Each is cheap when nothing it cares about moved.
    private func queueChanged() {
        planCache()
        autoplayRequested = false
        appState?.stations.queueChanged()
        appState?.autoplay.queueChanged()
        appState?.guestDJ.queueChanged()
    }

    /// A mix or a station tops itself up, so Autoplay must not cap it with a carousel.
    var isSelfExtending: Bool {
        guard let appState else { return false }
        if queue.station?.isEndless == true { return true }
        return appState.mixes.mixes.contains {
            $0.title == queue.sourceDescription && $0.isExhausted != true
        }
    }

    /// A Guest DJ's picks, where it says. Not additions for Add to Up Next.
    func insertPicks(_ songs: [Song], afterOrderIndex index: Int) {
        guard !songs.isEmpty else { return }
        queue.insertPicks(songs, afterOrderIndex: index)
        refillWindow()
        persist()
    }

    func removeUpcoming(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        queue.removeUpcoming(ids: ids)
        refillWindow()
        persist()
    }

    /// Containers iOS cannot decode natively. Kept explicit rather than inverted from
    /// a supported list, so a container that merely lacks a MIME mapping is not
    /// needlessly transcoded.
    static func needsTranscode(_ suffix: String?) -> Bool {
        StreamingPolicy.needsTranscode(suffix)
    }

    private static func mimeType(for suffix: String?) -> String? {
        switch suffix?.lowercased() {
        case "flac": return "audio/flac"
        case "mp3": return "audio/mpeg"
        case "m4a", "aac", "mp4": return "audio/mp4"
        case "wav": return "audio/wav"
        case "aiff", "aif": return "audio/aiff"
        default: return nil
        }
    }

    // MARK: - Time and transitions

    private func tick(elapsed newElapsed: Double, isMoving: Bool) {
        elapsed = newElapsed
        // Only when it changes: this runs four times a second, and an observed property
        // assigned its own value can still count as a change to whatever reads it.
        if isBuffering != output.isBuffering { isBuffering = output.isBuffering }

        // The queue's duration comes from the server and can be absent or wrong; the
        // output knows the real one once the file or stream is open.
        //
        // Adopted whenever it becomes known, not only while ours is still zero. The old
        // guard meant a track with no server duration whose length the output could not
        // determine at first stayed at 0:00 for its whole play -- the player showed
        // "6:09 of 0:00" -- and it also meant a wrong server duration could never be
        // corrected.
        if output.duration > 0, abs(output.duration - duration) > 0.5 {
            duration = output.duration
            tracker.trackChanged(to: queue.current, duration: duration)
        } else if elapsed > duration, elapsed > 0 {
            // The file is longer than anything claiming to know its length.
            //
            // Panchiko's "Ginkgo" is the case that found this: the server says 157.4 s,
            // while its own size and bitrate imply 214 s — the FLAC's STREAMINFO is wrong,
            // and AVFoundation, which decodes the actual stream, keeps playing past the
            // end. Trusting the metadata left the slider parked at 2:37 with audio still
            // going. Whatever the tags say, the position that has already been reached is
            // a lower bound on the truth.
            duration = elapsed
            tracker.trackChanged(to: queue.current, duration: duration)
        } else if duration <= 0, let known = queue.current?.duration, known > 0 {
            // Last resort, and the one that actually matters: whatever went wrong when
            // this track started, the queue still knows how long it is. Checked every
            // tick, so a duration that failed to apply once corrects itself within a
            // quarter of a second instead of reading 0:00 for the whole track.
            duration = Double(known)
            tracker.trackChanged(to: queue.current, duration: duration)
        }

        // Autoplay goes on half a minute before the end, so its first track is there in
        // time to fade or run gaplessly into, however long Sweet Fades makes the overlap.
        if !autoplayRequested, isPlaying, !queue.hasUpNext, duration > 0,
           duration - elapsed < 30, let autoplay = appState?.autoplay, autoplay.isActive {
            autoplayRequested = true
            Task { await autoplay.extend() }
        }

        // A stalled stream still ticks, so listening time is only credited while the
        // audio is genuinely moving.
        if isPlaying, isMoving {
            tracker.advanced(to: elapsed)
        } else {
            tracker.interrupted(at: elapsed)
        }
    }

    /// The output moved on by itself, so follow it in the logical queue.
    private func handleAdvanced(to songID: String?) {
        guard let songID,
              let orderIndex = queue.order.firstIndex(where: { queue.tracks[$0].id == songID })
        else {
            // Ran off the end of the window -- the end of the queue, a track that could
            // not be loaded, or repeat-one reaching the end of its only track. The queue
            // decides, and the output is rebuilt from it.
            if queue.repeatMode == .one {
                appState?.sleepTimer.trackDidFinish(next: queue.current)
            }
            if queue.advance() {
                rebuildOutput(startPlaying: true, seekTo: 0)
            } else if let autoplay = appState?.autoplay, autoplay.isActive, autoplay.selectedOption != nil {
                // The end came before Autoplay's tracks did — a short last track, or a
                // slow server. Wait for them rather than stopping.
                Task {
                    if await autoplay.extend(), queue.advance() {
                        rebuildOutput(startPlaying: true, seekTo: 0)
                    } else {
                        appState?.sleepTimer.trackDidFinish(next: nil)
                        pause()
                    }
                }
            } else {
                appState?.sleepTimer.trackDidFinish(next: nil)
                pause()
            }
            return
        }

        appState?.sleepTimer.trackDidFinish(next: queue.tracks[queue.order[orderIndex]])
        topUpMixQueue()
        // Played to the end: there is nothing to come back to.
        if let finished = queue.current { appState?.resume.clear(songID: finished.id) }
        resumeNotice = nil

        queue.position = orderIndex
        duration = output.duration > 0 ? output.duration : Double(queue.current?.duration ?? 0)
        elapsed = 0
        tracker.trackChanged(to: queue.current, duration: duration)
        refillWindow()
        publishNowPlaying(force: true)
        persist()
    }

    // MARK: - Now Playing

    private func publishNowPlaying(force: Bool) {
        guard let song = queue.current else {
            nowPlaying.clear()
            return
        }

        nowPlaying.update(
            song: song,
            elapsed: elapsed,
            duration: duration > 0 ? duration : Double(song.duration ?? 0),
            isPlaying: isPlaying,
            speed: speed,
            queueIndex: queue.position,
            queueCount: queue.order.count
        )

        if let artwork = appState?.artwork {
            let id = song.coverArt
            let songID = song.id
            Task { @MainActor in
                guard let image = await artwork.image(for: id, size: .full) else { return }
                // Two guards, both needed. The song id lets `update` tell whether the
                // artwork it already has belongs to the track being published -- passing
                // nil made it clear and re-fetch the artwork on every play/pause, which
                // is a visible blink on the lock screen. And a fetch that started for
                // the previous track must not land on this one.
                guard queue.current?.id == songID else { return }
                nowPlaying.setArtwork(image, songID: songID)
            }
            // The next two tracks' covers too, at the player's size and the rows', so a
            // skip lands on its artwork rather than on a grey square that fills in.
            let coming = queue.upcoming(2).map(\.coverArt)
            artwork.prefetch(coming, size: .full)
            artwork.prefetch(coming, size: .thumb)
        }
    }

    // MARK: - Persistence

    /// Debounced, plus forced on the transitions that matter. Backgrounding does not
    /// kill the app while audio plays; the real risks are termination while paused
    /// and crashes.
    private func persist() {
        saveTask?.cancel()
        let snapshot = QueueSnapshot(queue: queue, positionSeconds: elapsed, savedAt: .now)
        lastSavedAt = snapshot.savedAt
        saveTask = Task { [store] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await store.save(snapshot)
        }
        // Debounced inside QueueSync, so this is safe on every transition.
        appState?.queueSync.push(queue: queue, elapsed: elapsed)
    }

    func persistNow() {
        let snapshot = QueueSnapshot(queue: queue, positionSeconds: elapsed, savedAt: .now)
        lastSavedAt = snapshot.savedAt
        Task { [store] in await store.save(snapshot) }
        appState?.queueSync.pushNow(queue: queue, elapsed: elapsed)
    }

    /// Restores the previous queue **paused**. Auto-playing on launch is hostile.
    func restore() async {
        guard let snapshot = await store.load(), !snapshot.queue.isEmpty else { return }
        lastSavedAt = snapshot.savedAt
        queue = snapshot.queue
        rebuildOutput(startPlaying: false, seekTo: snapshot.positionSeconds)
    }
}
