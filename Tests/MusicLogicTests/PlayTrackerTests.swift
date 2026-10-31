import Foundation
import Testing

@testable import MusicLogic

/// The scrobbler decides what counts as a play. Getting it wrong is invisible until the
/// server's history is already wrong, which is exactly the kind of thing worth testing.
@MainActor
struct PlayTrackerTests {
    private func song(_ duration: Int) -> Song {
        var song = Song(id: "s1", title: "Track")
        song.duration = duration
        return song
    }

    /// Advancing in realistic 0.25 s steps, the way the 4 Hz observer does.
    private func listen(_ tracker: PlayTracker, seconds: Double, from start: Double = 0) {
        var elapsed = start
        while elapsed < start + seconds {
            elapsed += 0.25
            tracker.advanced(to: elapsed)
        }
    }

    @Test func announcesNowPlayingOnlyOnceAudioActuallyMoves() {
        let tracker = PlayTracker()
        var announced = 0
        tracker.onNowPlaying = { _ in announced += 1 }

        tracker.trackChanged(to: song(200), duration: 200)
        // Selected but not playing -- a queue restored paused at launch must not tell the
        // server anything.
        #expect(announced == 0)

        listen(tracker, seconds: 1)
        #expect(announced == 1)

        listen(tracker, seconds: 5, from: 1)
        #expect(announced == 1)
    }

    /// The same song again -- repeat-one going round, or played again once finished --
    /// is a second play. It used to read as "no change" and never count twice.
    @Test func theSameSongPlayedAgainCountsAgain() {
        let tracker = PlayTracker()
        var counted = 0
        tracker.onPlayCounted = { _ in counted += 1 }

        tracker.trackChanged(to: song(100), duration: 100)
        listen(tracker, seconds: 60)
        #expect(counted == 1)

        tracker.trackChanged(to: song(100), duration: 100, isNewPlay: true)
        tracker.interrupted(at: 0)
        listen(tracker, seconds: 60)
        #expect(counted == 2)
    }

    /// A duration that is only now known is the same play, not a new one.
    @Test func aLateDurationIsNotANewPlay() {
        let tracker = PlayTracker()
        var counted = 0
        tracker.onPlayCounted = { _ in counted += 1 }

        tracker.trackChanged(to: song(100), duration: 100)
        listen(tracker, seconds: 60)
        tracker.trackChanged(to: song(100), duration: 100)
        listen(tracker, seconds: 30, from: 60)
        #expect(counted == 1)
    }

    @Test func countsAPlayAtHalfTheTrack() {
        let tracker = PlayTracker()
        var counted: [String] = []
        tracker.onPlayCounted = { counted.append($0.songID) }

        tracker.trackChanged(to: song(100), duration: 100)
        listen(tracker, seconds: 49)
        #expect(counted.isEmpty)

        listen(tracker, seconds: 3, from: 49)
        #expect(counted == ["s1"])
    }

    @Test func countsAPlayAtFourMinutesForALongTrack() {
        let tracker = PlayTracker()
        var counted = 0
        tracker.onPlayCounted = { _ in counted += 1 }

        // A 20-minute track: half would be 10 minutes, but the cap is 4.
        tracker.trackChanged(to: song(1200), duration: 1200)
        listen(tracker, seconds: 239)
        #expect(counted == 0)

        listen(tracker, seconds: 3, from: 239)
        #expect(counted == 1)
    }

    /// The headline rule: scrubbing to the end is not listening.
    @Test func seekingToTheEndDoesNotScrobble() {
        let tracker = PlayTracker()
        var counted = 0
        tracker.onPlayCounted = { _ in counted += 1 }

        tracker.trackChanged(to: song(300), duration: 300)
        listen(tracker, seconds: 5)

        // One giant jump, as a seek produces.
        tracker.advanced(to: 299)
        #expect(counted == 0)
    }

    @Test func aPlayIsCountedOnlyOncePerTrack() {
        let tracker = PlayTracker()
        var counted = 0
        tracker.onPlayCounted = { _ in counted += 1 }

        tracker.trackChanged(to: song(60), duration: 60)
        listen(tracker, seconds: 59)
        #expect(counted == 1)
    }

    /// Pausing must not accumulate: the gap across a pause is a jump, not listening.
    @Test func timeSpentPausedDoesNotCount() {
        let tracker = PlayTracker()
        var counted = 0
        tracker.onPlayCounted = { _ in counted += 1 }

        tracker.trackChanged(to: song(100), duration: 100)
        listen(tracker, seconds: 20)
        tracker.interrupted(at: 20)
        // Resumes at the same spot after an hour away.
        listen(tracker, seconds: 20, from: 20)

        #expect(counted == 0)
    }

    @Test func changingTrackResetsAccumulation() {
        let tracker = PlayTracker()
        var counted: [String] = []
        tracker.onPlayCounted = { counted.append($0.songID) }

        tracker.trackChanged(to: song(100), duration: 100)
        listen(tracker, seconds: 40)
        #expect(counted.isEmpty)

        var next = Song(id: "s2", title: "Next")
        next.duration = 100
        tracker.trackChanged(to: next, duration: 100)
        listen(tracker, seconds: 40)
        // 40 s on each is not 80 s on either.
        #expect(counted.isEmpty)
    }

    /// A short interlude would never reach "half the track" in 0.25 s steps if the
    /// threshold had no floor, so very short tracks get a fixed one.
    @Test func veryShortTracksStillScrobble() {
        let tracker = PlayTracker()
        var counted = 0
        tracker.onPlayCounted = { _ in counted += 1 }

        tracker.trackChanged(to: song(20), duration: 20)
        listen(tracker, seconds: 19)
        #expect(counted == 1)
    }

    /// The submitted time is when the listen began, not when the threshold was crossed,
    /// so a scrobble flushed from the outbox days later is filed at the right hour.
    @Test func listenTimeIsStampedWhenPlaybackStarted() {
        let tracker = PlayTracker()
        var event: PlayTracker.Event?
        tracker.onPlayCounted = { event = $0 }

        tracker.trackChanged(to: song(60), duration: 60)
        let before = Date.now
        listen(tracker, seconds: 40)

        let stamped = try? #require(event?.listenedAt)
        if let stamped {
            // Stamped at the start of the listen, so it cannot be after the threshold
            // was crossed.
            #expect(stamped >= before.addingTimeInterval(-1))
            #expect(stamped <= Date.now)
        }
    }
}
