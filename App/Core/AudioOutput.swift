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
