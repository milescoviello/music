import XCTest
@testable import Music

/// `PlaybackController` is the file most often touched by a fix, and until these it had no
/// test at all. They drive it through `FakeOutput`, the way the real player would: a load,
/// ticks, the player moving on by itself, a stream that cannot be reached. Run in the iOS
/// simulator (hosted in the app) by CI on the build VM.
@MainActor
final class PlaybackControllerTests: XCTestCase {
    private func songs(_ ids: String...) -> [Song] {
        ids.map { id in
            var song = Song(id: id, title: "Track \(id)")
            song.artist = "Artist \(id)"
            song.duration = 200
            return song
        }
    }

    /// Each test's queue file goes in a folder of its own. These run inside the app, and
    /// the default store is the app's real one: every CI run used to leave "Track a/b/c"
    /// behind as the queue the simulator's app restored at its next launch.
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlaybackControllerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func make() -> (PlaybackController, FakeOutput) {
        let output = FakeOutput()
        let store = PlaybackQueueStore(directory: folder)
        return (PlaybackController(output: output, store: store), output)
    }

    func testPlayStartsAtTheChosenTrack() {
        let (player, output) = make()
        player.play(songs: songs("a", "b", "c"), startingAt: 1, source: "test")

        XCTAssertEqual(player.currentSong?.id, "b")
        XCTAssertEqual(output.loads.last?.ids.first, "b")
        XCTAssertTrue(player.isPlaying)
        XCTAssertGreaterThan(output.plays, 0)
    }

    func testNextLoadsTheFollowingTrack() {
        let (player, output) = make()
        player.play(songs: songs("a", "b", "c"), startingAt: 0, source: "test")

        player.next()

        XCTAssertEqual(player.currentSong?.id, "b")
        XCTAssertEqual(output.loads.last?.ids.first, "b")
        XCTAssertEqual(output.loads.last?.startAt, 0)
    }

    /// Every native player rewinds first and only goes back from the very start.
    func testPreviousRewindsFirstThenGoesBack() {
        let (player, output) = make()
        player.play(songs: songs("a", "b", "c"), startingAt: 1, source: "test")

        output.onTick?(42, true)
        player.previous()
        XCTAssertEqual(player.currentSong?.id, "b", "past 3 s, previous restarts the track")
        XCTAssertEqual(output.seeks.last, 0)

        output.onTick?(1, true)
        player.previous()
        XCTAssertEqual(player.currentSong?.id, "a", "at the start, previous goes back")
    }

    /// The gapless case: the player already held the next track and moved on by itself,
    /// so the queue follows without loading anything again.
    func testThePlayerMovingOnByItselfMovesTheQueueWithoutReloading() {
        let (player, output) = make()
        player.play(songs: songs("a", "b", "c"), startingAt: 0, source: "test")
        let loads = output.loads.count

        output.onAdvanced?("b")

        XCTAssertEqual(player.currentSong?.id, "b")
        XCTAssertEqual(player.elapsed, 0)
        XCTAssertEqual(output.loads.count, loads)
    }

    /// Without Autoplay, next on the last track pauses there rather than going anywhere.
    func testNextOnTheLastTrackPausesWithoutAutoplay() {
        let (player, output) = make()
        player.play(songs: songs("a"), startingAt: 0, source: "test")

        player.next()

        XCTAssertEqual(player.currentSong?.id, "a")
        XCTAssertFalse(player.isPlaying)
        XCTAssertGreaterThan(output.pauses, 0)
    }

    /// The player ran out of tracks (`onAdvanced(nil)`) with nothing queued after: stop.
    func testRunningOffTheEndOfTheQueueStops() {
        let (player, output) = make()
        player.play(songs: songs("a"), startingAt: 0, source: "test")
        XCTAssertTrue(player.isPlaying)

        output.onAdvanced?(nil)

        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.currentSong?.id, "a")
    }

    /// A stream that cannot be reached is held, paused, and named -- not skipped past.
    func testAnUnreachableTrackIsHeldAndPaused() {
        let (player, output) = make()
        player.play(songs: songs("a", "b"), startingAt: 0, source: "test")

        output.onUnreachable?("a")

        XCTAssertEqual(player.currentSong?.id, "a")
        XCTAssertEqual(player.unreachableSongID, "a")
        XCTAssertFalse(player.isPlaying)
        XCTAssertGreaterThan(output.pauses, 0)
    }

    /// A report about a track that is not the one playing (a preloaded one) changes nothing.
    func testUnreachableForAnotherTrackIsIgnored() {
        let (player, output) = make()
        player.play(songs: songs("a", "b"), startingAt: 0, source: "test")

        output.onUnreachable?("b")

        XCTAssertNil(player.unreachableSongID)
        XCTAssertTrue(player.isPlaying)
    }

    /// Pressing play on a track that never loaded loads it again, rather than "resuming"
    /// an output that holds nothing (which played silence).
    func testPlayAfterAFailedLoadLoadsTheTrackAgain() {
        let (player, output) = make()
        player.play(songs: songs("a", "b"), startingAt: 0, source: "test")
        output.onUnreachable?("a")
        output.holdsCurrent = false
        let loads = output.loads.count

        player.play()

        XCTAssertGreaterThan(output.loads.count, loads)
        XCTAssertEqual(output.loads.last?.ids.first, "a")
    }

    /// The server's duration can be missing or wrong; the player's real one wins.
    func testATickAdoptsThePlayersRealDuration() {
        let (player, output) = make()
        player.play(songs: songs("a"), startingAt: 0, source: "test")

        output.duration = 321
        output.onTick?(5, true)

        XCTAssertEqual(player.duration, 321)
        XCTAssertEqual(player.elapsed, 5)
    }
}
