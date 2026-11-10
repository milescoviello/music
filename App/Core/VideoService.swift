import Foundation
import Observation

/// The player's Song | Video switch, Change Video, and watching a YouTube result from
/// search -- YouTube Music's video side, with no ads.
///
/// A song's video is found by the sonic service and played through it as plain HLS (see
/// `VideoClient`). While a video plays it stands in for the track: `PlaybackController.video`
/// sends play, pause and seek here -- from the player, the lock screen and headphones alike
/// -- and shows the video's time, and the track waits paused underneath. Switching back
/// picks the track up where the video had got to.
///
/// The switch is remembered, and stays on from song to song: each song plays its video when
/// it has one and its own track when it has not, and the next song's video is looked up
/// ahead so the change is quick. Watching a song's video counts as listening to it. The
/// video's sound is YouTube's, which is lossy, and it keeps playing with the screen locked;
/// the Song side is the library's own file, untouched.
///
/// A search result is watched by itself: what was playing pauses, the video plays full
/// screen, and closing it picks the music up again where it was.
@MainActor
@Observable
final class VideoService: VideoStandIn {
    /// What is known of a song's video.
    enum Lookup: Equatable, Sendable {
        case looking
        case found(VideoClient.Match)
        case unavailable
        case failed

        var video: VideoClient.Video? {
            if case let .found(match) = self { return match.video }
            return nil
        }
    }

    /// What the player shows for the song playing.
    enum Showing: Equatable, Sendable {
        case song
        /// Video chosen, and its video being found or opened.
        case loading
        case video
        /// Video chosen, but this song has none: its track plays.
        case noVideo
        /// The video would not play: its track plays instead.
        case failed(String)
    }

    struct Progress: Equatable, Sendable {
        var elapsed: Double = 0
        var duration: Double = 0
        var isPlaying = false
        var isWaiting = false
    }

    private static let wantsVideoKey = "video.wantsVideo"

    /// Video chosen on the switch. Remembered between launches.
    private(set) var wantsVideo: Bool {
        didSet { UserDefaults.standard.set(wantsVideo, forKey: Self.wantsVideoKey) }
    }
    private(set) var showing: Showing = .song
    /// Each song's video, by song id, as far as it is known.
    private(set) var lookups: [String: Lookup] = [:]
    /// A search result being watched by itself.
    private(set) var watching: VideoClient.Video?
    /// The video open now, a song's or one being watched.
    private(set) var current: VideoClient.Video?
    private(set) var progress = Progress()
    /// Why the video being watched stopped, for its screen.
    private(set) var watchError: String?

    let engine = VideoEngine()

    @ObservationIgnored private weak var appState: AppState?
    /// The song whose video stands in for its track, while one does. Observed: whether
    /// the player shows the video or the artwork reads it.
    private var songID: String?
    /// Seconds into the video the song's start is.
    @ObservationIgnored private var offset: Double = 0
    /// Bumped by every change of what should be showing, so an answer that comes back late
    /// for an older one is dropped.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var lookupTasks: [String: Task<Lookup, Never>] = [:]
    /// What to go back to when a watched video is closed.
    @ObservationIgnored private var afterWatching: (songVideo: Bool, playing: Bool, position: Double)?

    init() {
        wantsVideo = UserDefaults.standard.bool(forKey: Self.wantsVideoKey)
    }

    func configure(appState: AppState) {
        self.appState = appState
        engine.onProgress = { [weak self] progress in self?.engineProgressed(progress) }
        engine.onEnd = { [weak self] in self?.engineEnded() }
        engine.onFailure = { [weak self] message in self?.engineFailed(message) }
    }

    var client: VideoClient {
        VideoClient(configuration: appState?.sonic.configuration ?? .default)
    }

    /// The service answers, and this device is playing for itself rather than to another.
    var isAvailable: Bool {
        guard let appState else { return false }
        return appState.sonic.status != nil && appState.player.remote == nil
    }

    /// Whether a song's video is standing in for its track.
    var isStandingIn: Bool { songID != nil }

    /// What the player's quality line says while `song`'s video is what is heard: not the
    /// file's format, which is not what is playing.
    func soundDescription(for song: Song) -> String? {
        songID == song.id && showing == .video ? "Video · YouTube audio" : nil
    }

    func lookup(for song: Song) -> Lookup? { lookups[song.id] }

    // MARK: - Finding a song's video

    /// The song's video, looked up once and remembered. `warm` asks the service to open
    /// its streams ahead, so switching to it is quick.
    @discardableResult
    func find(_ song: Song, warm: Bool = true) async -> Lookup {
        if let known = lookups[song.id], known != .looking, known != .failed { return known }
        if let running = lookupTasks[song.id] { return await running.value }
        lookups[song.id] = .looking
        let client = client
        let artist = song.artist ?? ""
        let title = song.title
        let duration = song.duration.map(Double.init)
        let task = Task<Lookup, Never> {
            do {
                let match = try await client.match(artist: artist, title: title, duration: duration, warm: warm)
                return match.video == nil ? .unavailable : .found(match)
            } catch {
                await Diagnostics.shared.record("video", "lookup failed: \(error.localizedDescription)")
                return .failed
            }
        }
        lookupTasks[song.id] = task
        let answer = await task.value
        lookupTasks[song.id] = nil
        lookups[song.id] = answer
        return answer
    }

    /// For the player: the song on screen, and with Video on, the one after it. Also where
    /// a remembered Video switch catches up once the service has answered.
    func prepare(_ song: Song) async {
        guard isAvailable else { return }
        await find(song)
        if wantsVideo, let next = appState?.player.queue.upcoming(1).first {
            await find(next)
        }
    }

    // MARK: - The switch

    func setWantsVideo(_ on: Bool) {
        guard on != wantsVideo else { return }
        if on {
            guard isAvailable, let player = appState?.player, let song = player.currentSong else { return }
            wantsVideo = true
            show(song, at: player.elapsed, playing: player.isPlaying)
        } else {
            wantsVideo = false
            backToSong(play: nil)
        }
    }

    /// Video was left on -- from the last launch, or a song before this one that had no
    /// video -- and play was pressed: the song's video plays, when it has one.
    func takesOverPlay() -> Bool {
        guard wantsVideo, songID == nil, watching == nil, isAvailable,
              let player = appState?.player, let song = player.currentSong
        else { return false }
        switch lookups[song.id] {
        case .unavailable, .failed: return false
        default: break
        }
        show(song, at: player.elapsed, playing: true)
        return true
    }

    /// The video for `song` in its track's place, from `seconds` into the track.
    private func show(_ song: Song, at seconds: Double, playing: Bool) {
        guard let player = appState?.player else { return }
        generation += 1
        let generation = generation
        engine.stop()
        current = nil
        showing = .loading
        songID = song.id
        progress = Progress(elapsed: seconds, duration: Double(song.duration ?? 0), isPlaying: playing, isWaiting: true)
        // Taken over before the lookup, so the track is not heard while it runs.
        player.beginVideo(self)
        player.mirrorVideo(elapsed: seconds, duration: Double(song.duration ?? 0), isPlaying: playing, isBuffering: true)

        Task {
            let lookup = await find(song)
            guard self.generation == generation, songID == song.id else { return }
            // Read now, not when asked: a pause while the video was being found counts.
            let playingNow = player.isPlaying
            guard case let .found(match) = lookup, let video = match.video else {
                showing = lookup == .failed ? .failed("Couldn't reach the video service.") : .noVideo
                songID = nil
                current = nil
                progress = Progress()
                player.endVideo(resumingAt: seconds, play: playingNow)
                return
            }
            offset = match.offset
            current = video
            showing = .video
            engine.open(videoID: video.id, client: client, at: max(0, seconds + match.offset), playing: playingNow)
        }
    }

    /// Back to the track, where the video had got to. `play` nil keeps the state it had.
    private func backToSong(play: Bool?) {
        generation += 1
        guard songID != nil else {
            showing = .song
            return
        }
        let wasPlaying = appState?.player.isPlaying ?? false
        let position = songPosition
        engine.stop()
        songID = nil
        current = nil
        progress = Progress()
        showing = .song
        appState?.player.endVideo(resumingAt: position, play: play ?? wasPlaying)
    }

    /// Where in the track the video standing in has got to.
    private var songPosition: Double {
        showing == .video ? max(0, progress.elapsed - offset) : (appState?.player.elapsed ?? 0)
    }

    /// From `PlaybackController`, whenever the song playing changes -- before its track is
    /// loaded, so it is never heard ahead of its video.
    func trackChanged() {
        guard let player = appState?.player else { return }
        // Something else was put on while a search result was being watched: it wins.
        if watching != nil { finishWatching(resume: false) }
        guard let song = player.currentSong else {
            if songID != nil { backToSong(play: false) }
            return
        }
        guard wantsVideo, isAvailable else {
            if songID != nil { backToSong(play: nil) }
            showing = .song
            return
        }
        if songID == song.id { return }
        // A video standing in carries its playing state on; otherwise the track's.
        show(song, at: 0, playing: player.isPlaying)
    }

    /// Another device is being played to: the video stops. The switch is kept for later.
    func playerWentRemote() {
        generation += 1
        engine.stop()
        songID = nil
        watching = nil
        afterWatching = nil
        current = nil
        showing = .song
        progress = Progress()
    }

    // MARK: - Change Video

    /// What the Change Video list offers: YouTube's results for the song, or for what was
    /// typed. A pasted link is that one video.
    func candidates(for song: Song, query: String? = nil) async -> [VideoClient.Video] {
        let typed = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let id = VideoClient.videoID(fromLink: typed) {
            if let streams = try? await client.streams(videoID: id) {
                return [VideoClient.Video(id: id, title: streams.title, channel: streams.channel, duration: streams.duration)]
            }
            return [VideoClient.Video(id: id, title: "YouTube video \(id)", channel: "")]
        }
        let text = typed.isEmpty ? [song.artist, song.title].compactMap { $0 }.joined(separator: " ") : typed
        return (try? await client.search(text, limit: 15)) ?? []
    }

    /// From now on this song plays `video`, on every device.
    func choose(_ video: VideoClient.Video, for song: Song) async -> Bool {
        guard let match = try? await client.choose(video, artist: song.artist ?? "", title: song.title) else {
            return false
        }
        lookups[song.id] = .found(match)
        reloadIfShowing(song)
        return true
    }

    /// Back to the video the service picks itself.
    func useAutomatic(for song: Song) async -> Bool {
        guard (try? await client.useAutomatic(artist: song.artist ?? "", title: song.title)) != nil else {
            return false
        }
        lookups[song.id] = nil
        await find(song)
        reloadIfShowing(song)
        return true
    }

    /// The pick changed under the song on screen: play the new one from the same place.
    private func reloadIfShowing(_ song: Song) {
        guard let player = appState?.player, player.currentSong?.id == song.id, wantsVideo, isAvailable,
              watching == nil
        else { return }
        let seconds = songID == song.id ? songPosition : player.elapsed
        let playing = player.isPlaying
        songID = nil
        show(song, at: seconds, playing: playing)
    }

    // MARK: - Watching a search result

    /// YouTube's results for a search; nil when the search did not go through.
    func search(_ query: String) async -> [VideoClient.Video]? {
        guard isAvailable else { return nil }
        return try? await client.search(query, limit: 15)
    }

    /// Plays a search result by itself, full screen. What was playing pauses, and picks up
    /// again where it was when the video is closed.
    func watch(_ video: VideoClient.Video) {
        guard let player = appState?.player, player.remote == nil else { return }
        if watching != nil { finishWatching(resume: false) }
        let songVideo = songID != nil
        let playing = player.isPlaying
        let position = songVideo ? songPosition : player.elapsed
        if songVideo {
            // Its place kept: the switch stays on Video, and closing brings it back.
            generation += 1
            engine.stop()
            songID = nil
            current = nil
            showing = .song
            player.endVideo(resumingAt: position, play: false)
        } else if playing {
            player.pause()
        }
        afterWatching = (songVideo, playing, position)

        generation += 1
        watching = video
        current = video
        watchError = nil
        offset = 0
        progress = Progress(duration: video.duration ?? 0, isPlaying: true, isWaiting: true)
        // A stand-in too, so the lock screen and headphones drive the video, not the
        // paused music underneath -- shown there as the video, and never counted as a play.
        player.beginVideo(self, showing: Song(
            id: "youtube:\(video.id)", title: video.title, artist: video.channel,
            duration: video.duration.map { Int($0.rounded()) }
        ))
        engine.open(videoID: video.id, client: client, at: 0, playing: true)
    }

    /// Closes the video being watched, and the music carries on where it was.
    func stopWatching() {
        finishWatching(resume: true)
    }

    private func finishWatching(resume: Bool) {
        guard watching != nil else { return }
        generation += 1
        engine.stop()
        watching = nil
        current = nil
        watchError = nil
        progress = Progress()
        let back = afterWatching
        afterWatching = nil
        guard let player = appState?.player else { return }
        player.endVideo(resumingAt: back?.position, play: false)
        guard resume, let back else { return }
        if back.songVideo, wantsVideo, isAvailable, let song = player.currentSong {
            show(song, at: back.position, playing: back.playing)
        } else if back.playing {
            player.play()
        }
    }

    // MARK: - Transport, for the one being watched

    func togglePlayPause() {
        progress.isPlaying ? pause() : play()
    }

    func skip(by seconds: Double) {
        seek(to: min(max(0, progress.elapsed + seconds), max(0, progress.duration - 1)))
    }

    // MARK: - VideoStandIn

    func play() {
        engine.play()
    }

    func pause() {
        engine.pause()
    }

    func seek(to seconds: Double) {
        engine.seek(to: seconds)
        progress.elapsed = seconds
    }

    // MARK: - The engine

    private func engineProgressed(_ update: VideoEngine.Progress) {
        let next = Progress(elapsed: update.elapsed, duration: update.duration,
                            isPlaying: update.isPlaying, isWaiting: update.isWaiting)
        if next != progress { progress = next }
        if songID != nil || watching != nil {
            appState?.player.mirrorVideo(elapsed: update.elapsed, duration: update.duration,
                                         isPlaying: update.isPlaying, isBuffering: update.isWaiting)
        }
    }

    private func engineEnded() {
        if watching != nil {
            progress.isPlaying = false
            appState?.player.mirrorVideo(elapsed: progress.elapsed, duration: progress.duration,
                                         isPlaying: false, isBuffering: false)
            return
        }
        guard songID != nil, let player = appState?.player else { return }
        let before = player.currentSong?.id
        player.videoFinished()
        // Repeat one, or the same song again: there is no change of song to follow, so
        // its video starts over.
        if player.currentSong?.id == before, songID == before, player.isPlaying {
            engine.seek(to: offset)
            engine.play()
        }
    }

    private func engineFailed(_ message: String) {
        Task { await Diagnostics.shared.record("video", "playback failed: \(message)") }
        if watching != nil {
            watchError = message
            progress.isPlaying = false
            progress.isWaiting = false
            appState?.player.mirrorVideo(elapsed: progress.elapsed, duration: progress.duration,
                                         isPlaying: false, isBuffering: false)
            return
        }
        guard songID != nil, let song = appState?.player.currentSong else { return }
        let position = songPosition
        let playing = appState?.player.isPlaying ?? false
        generation += 1
        lookups[song.id] = .failed
        engine.stop()
        songID = nil
        current = nil
        progress = Progress()
        showing = .failed(message)
        appState?.player.endVideo(resumingAt: position, play: playing)
    }
}

/// What a music video standing in for the track answers to (see `PlaybackController.video`).
@MainActor
protocol VideoStandIn: AnyObject {
    func play()
    func pause()
    func seek(to seconds: Double)
}
