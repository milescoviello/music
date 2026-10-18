import Foundation
import Testing

@testable import MusicLogic

/// The queue is where the bugs that actually reached the phone came from, so it gets the
/// most attention. Shuffle in particular shipped broken: it always started on track 1.
struct PlaybackQueueTests {
    private func songs(_ count: Int) -> [Song] {
        (1...count).map { index in
            Song(id: "s\(index)", title: "Track \(index)")
        }
    }

    @Test func startsAtTheRequestedTrack() {
        let queue = PlaybackQueue.make(
            tracks: songs(5), startingAt: 2, shuffled: false, source: "Album"
        )
        #expect(queue.current?.id == "s3")
        #expect(queue.order == [0, 1, 2, 3, 4])
        #expect(queue.isShuffled == false)
    }

    /// The regression that shipped: `make(shuffled: true)` kept the current track pinned
    /// to position 0, so "Shuffle" always began with track 1 and only the tail was
    /// random. With enough tracks, always landing on the first one is not luck.
    @Test func shuffleDoesNotAlwaysStartOnTheFirstTrack() {
        var firstTrackWins = 0
        for _ in 0..<80 {
            let queue = PlaybackQueue.make(
                tracks: songs(20), startingAt: 0, shuffled: true, source: "Album"
            )
            if queue.current?.id == "s1" { firstTrackWins += 1 }
        }
        // Expected ~4 of 80 by chance; the bug produced exactly 80.
        #expect(firstTrackWins < 25)
    }

    @Test func shuffleIsAPermutationSoNothingIsLostOrRepeated() {
        let queue = PlaybackQueue.make(
            tracks: songs(30), startingAt: 0, shuffled: true, source: "Album"
        )
        #expect(queue.order.count == 30)
        #expect(Set(queue.order) == Set(0..<30))
    }

    /// Unshuffling has to be exact, which is the whole reason the order is stored as a
    /// permutation rather than as a shuffled copy of the array.
    @Test func unshuffleRestoresOriginalOrderAndKeepsTheCurrentTrack() {
        var queue = PlaybackQueue.make(
            tracks: songs(12), startingAt: 0, shuffled: false, source: "Album"
        )
        queue.shuffle(keepingCurrent: true)
        queue.position = 4
        let playing = queue.current?.id

        queue.unshuffle()

        #expect(queue.order == Array(0..<12))
        #expect(queue.isShuffled == false)
        #expect(queue.current?.id == playing)
    }

    @Test func toggleShuffleMidPlaybackKeepsWhatIsPlaying() {
        var queue = PlaybackQueue.make(
            tracks: songs(15), startingAt: 7, shuffled: false, source: "Album"
        )
        let playing = queue.current?.id
        queue.shuffle(keepingCurrent: true)
        #expect(queue.current?.id == playing)
    }

    @Test func advanceStopsAtTheEndWhenRepeatIsOff() {
        var queue = PlaybackQueue.make(
            tracks: songs(3), startingAt: 2, shuffled: false, source: "Album"
        )
        queue.repeatMode = .off
        #expect(queue.advance() == false)
    }

    @Test func advanceWrapsWhenRepeatIsAll() {
        var queue = PlaybackQueue.make(
            tracks: songs(3), startingAt: 2, shuffled: false, source: "Album"
        )
        queue.repeatMode = .all
        #expect(queue.advance() == true)
        #expect(queue.current?.id == "s1")
    }

    @Test func advanceStaysPutWhenRepeatIsOne() {
        var queue = PlaybackQueue.make(
            tracks: songs(3), startingAt: 1, shuffled: false, source: "Album"
        )
        queue.repeatMode = .one
        #expect(queue.advance() == true)
        #expect(queue.current?.id == "s2")
    }

    @Test func rewindStopsAtTheStart() {
        var queue = PlaybackQueue.make(
            tracks: songs(3), startingAt: 0, shuffled: false, source: "Album"
        )
        queue.repeatMode = .off
        #expect(queue.rewind() == false)
    }

    @Test func insertNextPutsSongsImmediatelyAfterTheCurrentTrack() {
        var queue = PlaybackQueue.make(
            tracks: songs(4), startingAt: 0, shuffled: false, source: "Album"
        )
        queue.insertNext([Song(id: "new", title: "New")])
        #expect(queue.advance() == true)
        #expect(queue.current?.id == "new")
    }

    @Test func removingTheCurrentTrackLeavesAValidPosition() {
        var queue = PlaybackQueue.make(
            tracks: songs(3), startingAt: 1, shuffled: false, source: "Album"
        )
        queue.remove(atOrderIndex: 1)
        #expect(queue.tracks.count == 2)
        #expect(queue.order.count == 2)
        // Whatever it points at, it must not be out of bounds.
        #expect(queue.current != nil)
    }

    /// The bug this test was written for: `remove` dropped the song from the running
    /// order but not from `tracks`, and `unshuffle` rebuilds the order from
    /// `tracks.indices` -- so everything removed came back the moment shuffle was
    /// turned off.
    @Test func removedTracksDoNotComeBackWhenShuffleIsTurnedOff() {
        var queue = PlaybackQueue.make(
            tracks: songs(6), startingAt: 0, shuffled: true, source: "Album"
        )
        let doomed = queue.tracks[queue.order[3]].id

        queue.remove(atOrderIndex: 3)
        #expect(queue.order.count == 5)

        queue.unshuffle()

        #expect(queue.order.count == 5)
        #expect(queue.tracks.count == 5)
        #expect(queue.tracks.contains { $0.id == doomed } == false)
        // And the order must still be a valid permutation of what is left.
        #expect(Set(queue.order) == Set(0..<5))
    }

    @Test func removingSeveralTracksKeepsTheOrderConsistent() {
        var queue = PlaybackQueue.make(
            tracks: songs(8), startingAt: 0, shuffled: false, source: "Album"
        )
        queue.remove(atOrderIndex: 6)
        queue.remove(atOrderIndex: 2)
        queue.remove(atOrderIndex: 0)

        #expect(queue.tracks.count == 5)
        #expect(Set(queue.order) == Set(0..<5))
        #expect(queue.current != nil)
    }

    @Test func emptyQueueIsSafeToOperateOn() {
        var queue = PlaybackQueue()
        #expect(queue.current == nil)
        #expect(queue.advance() == false)
        #expect(queue.rewind() == false)
        queue.shuffle(keepingCurrent: true)
        queue.unshuffle()
        #expect(queue.isEmpty)
    }

    /// Multi-disc albums must play disc 1 through disc 2, not interleave by track number.
    @Test func albumOrderSortsDiscsBeforeTracks() {
        var second = Song(id: "b", title: "Disc 2 Track 1")
        second.discNumber = 2
        second.track = 1
        var first = Song(id: "a", title: "Disc 1 Track 9")
        first.discNumber = 1
        first.track = 9

        #expect(first.albumOrder < second.albumOrder)
    }

    @Test func snapshotRoundTripsThroughJSON() throws {
        var queue = PlaybackQueue.make(
            tracks: songs(6), startingAt: 3, shuffled: true, source: "Kid A"
        )
        queue.repeatMode = .all

        let snapshot = QueueSnapshot(queue: queue, positionSeconds: 42.5, savedAt: .now)
        let data = try JSONEncoder().encode(snapshot)
        let restored = try JSONDecoder().decode(QueueSnapshot.self, from: data)

        #expect(restored.queue.order == queue.order)
        #expect(restored.queue.position == queue.position)
        #expect(restored.queue.repeatMode == .all)
        #expect(restored.queue.sourceDescription == "Kid A")
        #expect(restored.positionSeconds == 42.5)
    }

    // MARK: - Plexamp's three insert points

    private func ids(_ queue: PlaybackQueue) -> [String] {
        queue.upNext.map(\.id)
    }

    @Test func addToUpNextFollowsTheLastAdditionSoAdditionsKeepTheirOrder() {
        var queue = PlaybackQueue.make(tracks: songs(3), startingAt: 0, shuffled: false, source: "Album")
        #expect(!queue.canAddToUpNext)

        queue.insertNext([Song(id: "a", title: "A")])
        #expect(queue.canAddToUpNext)
        queue.addToUpNext([Song(id: "b", title: "B")])
        queue.addToUpNext([Song(id: "c", title: "C")])
        #expect(ids(queue) == ["a", "b", "c", "s2", "s3"])

        // Play Next still jumps ahead of all of them.
        queue.insertNext([Song(id: "d", title: "D")])
        #expect(ids(queue) == ["d", "a", "b", "c", "s2", "s3"])
    }

    @Test func addToQueueGoesToTheEndAndIsNotAnAddition() {
        var queue = PlaybackQueue.make(tracks: songs(3), startingAt: 0, shuffled: false, source: "Album")
        queue.append([Song(id: "z", title: "Z")])
        #expect(ids(queue) == ["s2", "s3", "z"])
        #expect(!queue.canAddToUpNext)
    }

    @Test func onceTheLastAdditionHasPlayedUpNextIsAfterTheCurrentTrackAgain() {
        var queue = PlaybackQueue.make(tracks: songs(3), startingAt: 0, shuffled: false, source: "Album")
        queue.insertNext([Song(id: "a", title: "A")])
        _ = queue.advance() // a
        _ = queue.advance() // s2
        #expect(!queue.canAddToUpNext)
        queue.addToUpNext([Song(id: "b", title: "B")])
        #expect(ids(queue) == ["b", "s3"])
    }

    @Test func removingTheLastAdditionForgetsIt() {
        var queue = PlaybackQueue.make(tracks: songs(3), startingAt: 0, shuffled: false, source: "Album")
        queue.insertNext([Song(id: "a", title: "A")])
        queue.remove(atOrderIndex: 1)
        #expect(!queue.canAddToUpNext)

        // Removing a track stored before it shifts its index, not its identity.
        queue.insertNext([Song(id: "b", title: "B")])
        queue.remove(atOrderIndex: 0)
        #expect(queue.current?.id == "b")
        #expect(queue.canAddToUpNext)
        queue.addToUpNext([Song(id: "c", title: "C")])
        #expect(ids(queue) == ["c", "s2", "s3"])
    }

    @Test func earlierIsWhatAlreadyPlayedOldestFirst() {
        var queue = PlaybackQueue.make(tracks: songs(4), startingAt: 2, shuffled: false, source: "Album")
        #expect(queue.earlier.map(\.id) == ["s1", "s2"])
        queue.jump(toOrderIndex: 0)
        #expect(queue.earlier.isEmpty)
    }

    @Test func clearingKeepsOnlyTheTrackPlaying() {
        var queue = PlaybackQueue.make(tracks: songs(5), startingAt: 2, shuffled: true, source: "Album")
        let playing = queue.current?.id
        queue.clearAllButCurrent()
        #expect(queue.current?.id == playing)
        #expect(queue.upNext.isEmpty)
        #expect(queue.earlier.isEmpty)
        #expect(!queue.isShuffled)
    }

    @Test func aQueueSavedBeforeAdditionsWereTrackedStillDecodes() throws {
        let queue = PlaybackQueue.make(tracks: songs(2), startingAt: 0, shuffled: false, source: "Album")
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(queue)) as! [String: Any]
        object.removeValue(forKey: "lastAddedTrackIndex")
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(PlaybackQueue.self, from: data)
        #expect(decoded.lastAddedTrackIndex == nil)
        #expect(decoded.current?.id == "s1")
    }
}
