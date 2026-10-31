import Foundation

/// Decides *when* a play counts, and remembers *when it happened*.
///
/// Two rules, both from the Subsonic/Last.fm convention Navidrome follows:
///
/// - A play is submitted once accumulated listening passes half the track or four
///   minutes, whichever comes first. Accumulated, not wall clock: scrubbing to the
///   end must not scrobble, and pausing for an hour mid-song must not either.
/// - The submission carries the moment the track *started*, not the moment the
///   request goes out. That is what keeps history honest when a scrobble is flushed
///   from the outbox days later.
///
/// Deliberately knows nothing about the network: the sink is injected, so the
/// direct-to-server version here and the durable outbox that replaces it later are
/// the same code path from the tracker's point of view.
@MainActor
final class PlayTracker {
    struct Event: Sendable {
        let songID: String
        /// When the listen began, not when it was submitted.
        let listenedAt: Date
    }

    /// Fired when audio actually starts moving on a track, for
    /// `scrobble?submission=false`.
    var onNowPlaying: ((Event) -> Void)?
    /// Fired once per track, when the threshold is crossed.
    var onPlayCounted: ((Event) -> Void)?

    private var songID: String?
    private var duration: Double = 0
    private var startedAt = Date.now
    private var accumulated: Double = 0
    private var lastElapsed: Double = 0
    private var hasCounted = false
    private var hasAnnounced = false

    /// A 4 Hz observer at 1x rate should step ~0.25 s. Anything larger is a seek, a
    /// stall recovery or a resume after a pause, so it contributes nothing. The
    /// ceiling is generous because the observer is not delivered on a hard schedule.
    private let maxPlausibleStep: Double = 1.5

    /// Call when a different track becomes current. Flushes nothing: if the previous
    /// track had earned its play it was already submitted at the threshold, which is
    /// also what makes a force-quit mid-track lose nothing that was owed.
    ///
    /// `isNewPlay` for a track starting again, even the same one: repeat-one going round,
    /// a finished song played again, the same song twice in a row. Without it the same id
    /// read as "no change", the count from the last play stood, and every later play of
    /// that song went unscrobbled. Left false for a duration that is only now known.
    func trackChanged(to song: Song?, duration: Double, isNewPlay: Bool = false) {
        guard isNewPlay || song?.id != songID else {
            // Same track, but its duration may only now be known.
            if self.duration == 0 { self.duration = duration }
            return
        }

        songID = song?.id
        self.duration = duration
        startedAt = .now
        accumulated = 0
        lastElapsed = 0
        hasCounted = false
        hasAnnounced = false
    }

    /// Call from the periodic time observer, only while actually playing.
    func advanced(to elapsed: Double) {
        defer { lastElapsed = elapsed }

        let step = elapsed - lastElapsed
        guard step > 0, step <= maxPlausibleStep else { return }

        // Announced on real movement rather than on selection, so restoring a saved
        // queue paused at launch does not tell the server you are listening.
        if !hasAnnounced, let songID {
            hasAnnounced = true
            // Stamped here, not at selection: a queue restored at launch and resumed
            // two hours later must be recorded at the hour you pressed play.
            startedAt = .now
            onNowPlaying?(Event(songID: songID, listenedAt: startedAt))
        }

        accumulated += step

        guard !hasCounted, let songID, accumulated >= threshold else { return }
        hasCounted = true
        onPlayCounted?(Event(songID: songID, listenedAt: startedAt))
    }

    /// Resets the delta baseline so the gap spanning a pause or a seek is not
    /// mistaken for listening.
    func interrupted(at elapsed: Double) {
        lastElapsed = elapsed
    }

    private var threshold: Double {
        // Very short tracks (interludes, skits) would otherwise never scrobble.
        guard duration > 0 else { return 30 }
        return min(duration / 2, 240)
    }
}
