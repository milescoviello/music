import Foundation

/// Where a song's bytes are, and what they are.
struct MediaLocation: Sendable {
    let url: URL
    /// Needed only when streaming: `stream.view` has no path extension, so
    /// AVFoundation has nothing to sniff and FLAC fails to pick a decoder.
    let mimeType: String?
    /// A file on this phone — a download or a cached stream.
    let isLocal: Bool
}

/// The thing that actually makes sound.
///
/// There used to be two of these: `AVQueuePlayer` for streaming, and an `AVAudioEngine`
/// that could do EQ and crossfade but had no networking, so effects worked on downloads
/// only. There is now one — `QueuePlayerOutput` — because the processing tap puts the
/// effects inside `AVPlayer` itself, and a second player does the crossfade. The protocol
/// stays as the line between the queue logic in `PlaybackController` and the
/// AVFoundation details behind it.
@MainActor
protocol AudioOutput: AnyObject {
    /// Seconds into the current track.
    var elapsed: Double { get }
    /// Seconds, or 0 when not yet known.
    var duration: Double { get }
    var isBuffering: Bool { get }
    /// Why, while `isBuffering`, in the platform's own words; nil when it does not say.
    /// For the log: a stall at 0:00 on a file already on the phone is not a slow
    /// network, and without this the log could not tell what it was.
    var waitingReason: String? { get }
    /// Whether there is a current track to resume. False when nothing is loaded or the
    /// current track failed to load; resuming then is silence, so the controller loads
    /// it again instead.
    var holdsCurrent: Bool { get }
    /// The current track while it has still not opened, and when it was asked for; nil
    /// once it has, or with nothing loaded. A request that died -- the phone asleep in
    /// the middle of it, a network that dropped -- leaves a track that neither opens nor
    /// fails, and playing it waits for ever.
    var unopened: (songID: String, since: Date)? { get }
    /// For the sleep-timer fade. Multiplies with any crossfade ramp, never replaces it.
    var volume: Float { get set }
    /// Playback speed, pitch preserved. 1 is normal.
    var rate: Float { get set }

    /// Loads the current track plus the preload window, seeked to `startAt`.
    func load(window: [Song], startAt: Double)
    /// Replaces the upcoming part of the window without disturbing what is playing.
    func updateUpcoming(_ songs: [Song])
    /// Re-asks every transition: the tracks either side of one were just measured.
    func refreshTransitions()
    /// Rebuilds any not-yet-playing item for a song whose bytes are now elsewhere.
    func sourceChanged(for songID: String)

    func play()
    func pause()
    func seek(to seconds: Double)
    func stop()

    /// The output moved on by itself. The id is the song now playing, or nil when it
    /// ran off the end of the window and the controller has to decide what is next.
    var onAdvanced: ((String?) -> Void)? { get set }
    /// The current track could not be fetched: the server did not answer. The output
    /// holds the track rather than moving on, and the controller decides when to retry.
    var onUnreachable: ((String) -> Void)? { get set }
    /// A streamed track gave out partway, and the output moved past it: the id, and where
    /// it stopped. The controller decides whether to go back and try it again from there.
    var onFailedMidTrack: ((_ songID: String, _ position: Double) -> Void)? { get set }
    /// Roughly 4 Hz. `isMoving` is false while stalled, so the play tracker does not
    /// credit listening time to a buffering track.
    var onTick: ((_ elapsed: Double, _ isMoving: Bool) -> Void)? { get set }
    /// Where to find a song's bytes. Set by the controller; changes on sign-in.
    var locate: ((Song) -> MediaLocation?)? { get set }
    /// The processing chain for one track — its own gain, the shared EQ and limiter.
    var makeChain: ((Song) -> DSPChain)? { get set }
    /// How a transition should sound: seconds of crossfade, or nil for gapless.
    var transition: ((_ from: Song, _ to: Song) -> Double?)? { get set }

    /// Where to deliver PCM for the visualiser.
    func setSpectrumSink(_ buffer: AudioSampleBuffer?)
}

extension AudioOutput {
    /// An output that cannot say why it waits says nothing.
    var waitingReason: String? { nil }
    /// One that fetches its own bytes and reports its failures has nothing stuck to tell.
    var unopened: (songID: String, since: Date)? { nil }
}
