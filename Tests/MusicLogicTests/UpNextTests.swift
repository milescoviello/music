import Foundation
import Testing

@testable import MusicLogic

/// Up Next as Plexamp has it: what you add plays before the rest of the queue -- Play
/// Next at the front of what you added, Add to Up Next at its end -- and shuffling, or
/// turning shuffle off, never scatters it. Add to Queue is the very end.
struct UpNextTests {
    private func songs(_ count: Int) -> [Song] {
        (1...count).map { Song(id: "s\($0)", title: "Track \($0)") }
    }

    private func song(_ id: String) -> Song { Song(id: id, title: id) }

    private func upNext(_ queue: PlaybackQueue) -> [String] { queue.upNext.map(\.id) }

    @Test func playNextGoesFirstAndAddToUpNextAfterEverythingAdded() {
        var queue = PlaybackQueue.make(tracks: songs(4), startingAt: 0, shuffled: false, source: "Album")
        queue.insertNext([song("A")])
        queue.insertNext([song("B")])
        #expect(upNext(queue) == ["B", "A", "s2", "s3", "s4"])

        // After the last of what was added -- A, further down -- not after B, the most
        // recent, which put C ahead of A.
        queue.addToUpNext([song("C")])
        queue.addToUpNext([song("D")])
        #expect(upNext(queue) == ["B", "A", "C", "D", "s2", "s3", "s4"])
    }

    @Test func addToQueueIsTheVeryEnd() {
        var queue = PlaybackQueue.make(tracks: songs(3), startingAt: 0, shuffled: false, source: "Album")
        queue.insertNext([song("A")])
        queue.append([song("Z")])
        #expect(upNext(queue) == ["A", "s2", "s3", "Z"])
    }

    @Test func turningShuffleOffKeepsWhatWasAddedNext() {
        var queue = PlaybackQueue.make(tracks: songs(6), startingAt: 0, shuffled: true, source: "Album")
        queue.insertNext([song("A")])
        queue.addToUpNext([song("B")])
        queue.append([song("Z")])
        let playing = queue.current?.id

        queue.unshuffle()

        #expect(queue.current?.id == playing)
        let ids = upNext(queue)
        // What was added still comes next, in its order; Add to Queue is still last.
        #expect(Array(ids.prefix(2)) == ["A", "B"])
        #expect(ids.last == "Z")
        // And the album is back in its own order around them.
        let album = ids.filter { $0.hasPrefix("s") }
        #expect(album == album.sorted { Int($0.dropFirst())! < Int($1.dropFirst())! })
    }

    @Test func turningShuffleOnKeepsWhatWasAddedNext() {
        for _ in 0..<20 {
            var queue = PlaybackQueue.make(tracks: songs(10), startingAt: 2, shuffled: false, source: "Album")
            queue.insertNext([song("A")])
            queue.addToUpNext([song("B")])

            queue.shuffle(keepingCurrent: true)

            #expect(queue.current?.id == "s3")
            #expect(Array(upNext(queue).prefix(2)) == ["A", "B"])
            #expect(Set(queue.order) == Set(queue.tracks.indices))
        }
    }

    @Test func aSongPlayedAgainFromEarlierComesNextAndKeepsTheCurrentTrack() {
        var queue = PlaybackQueue.make(tracks: songs(5), startingAt: 3, shuffled: false, source: "Album")
        // s2, already played, to straight after s4 -- the queue's Play Next on Earlier.
        queue.move(fromOrderIndex: 1, toOrderIndex: queue.position + 1)
        #expect(queue.current?.id == "s4")
        #expect(upNext(queue) == ["s2", "s5"])
        #expect(queue.earlier.map(\.id) == ["s1", "s3"])
    }

    @Test func removingAnAlbumTrackKeepsAdditionsTrackedAcrossShuffle() {
        var queue = PlaybackQueue.make(tracks: songs(5), startingAt: 0, shuffled: false, source: "Album")
        queue.insertNext([song("A")])
        queue.remove(atOrderIndex: 3) // s3
        queue.shuffle(keepingCurrent: true)
        #expect(upNext(queue).first == "A")
        queue.unshuffle()
        #expect(upNext(queue) == ["A", "s2", "s4", "s5"])
    }

    @Test func clearingThenAddingStartsAFreshUpNext() {
        var queue = PlaybackQueue.make(tracks: songs(4), startingAt: 1, shuffled: false, source: "Album")
        queue.insertNext([song("A")])
        queue.clearAllButCurrent()
        #expect(queue.upNext.isEmpty)
        #expect(queue.canAddToUpNext == false)
        queue.insertNext([song("B")])
        queue.addToUpNext([song("C")])
        #expect(upNext(queue) == ["B", "C"])
    }

    /// A saved queue keeps knowing what was added.
    @Test func whatWasAddedSurvivesBeingSaved() throws {
        var queue = PlaybackQueue.make(tracks: songs(4), startingAt: 0, shuffled: true, source: "Album")
        queue.insertNext([song("A")])
        let decoded = try JSONDecoder().decode(PlaybackQueue.self, from: JSONEncoder().encode(queue))
        var restored = decoded
        restored.unshuffle()
        #expect(upNext(restored).first == "A")
    }
}
