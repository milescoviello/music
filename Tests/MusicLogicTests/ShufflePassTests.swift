import Foundation
import Testing

@testable import MusicLogic

/// A shuffled pass plays every queued song exactly once before anything repeats: the
/// order is a permutation, plain or Smart Shuffle, from the start or mid-queue with songs
/// added to play next. (Checked after a report of one song twice in a late-night run; the
/// log showed a three-song queue on Repeat All, with a skip in between, not a re-draw.)
struct ShufflePassTests {
    private func songs(_ count: Int) -> [Song] {
        (0..<count).map { index in
            Song(id: "s\(index)", title: "Track \(index)", artist: index % 3 == 0 ? "Mira Vale" : "The Lanterns")
        }
    }

    private func pass(_ queue: PlaybackQueue) -> [String] {
        var queue = queue
        var ids = [queue.current?.id].compactMap { $0 }
        while queue.advance() { ids += [queue.current?.id].compactMap { $0 } }
        return ids
    }

    @Test func aShuffledPassPlaysEachSongOnce() {
        for count in [1, 2, 3, 17, 367] {
            let tracks = songs(count)
            let queue = PlaybackQueue.make(tracks: tracks, startingAt: 0, shuffled: true, source: "test")
            let ids = pass(queue)
            #expect(ids.count == count)
            #expect(Set(ids) == Set(tracks.map(\.id)))
        }
    }

    @Test func smartShuffleIsAPermutationToo() {
        let tracks = songs(120)
        var generator = SystemRandomNumberGenerator()
        let lastPlayed = Dictionary(uniqueKeysWithValues: tracks.prefix(40).map { (MixEngine.identity($0), Date.now) })
        let order = SmartShuffle.order(Array(tracks.indices), of: tracks, lastPlayed: lastPlayed, skipped: [:], using: &generator)
        #expect(order.sorted() == Array(tracks.indices))
    }

    @Test func reshufflingMidQueueKeepsEveryoneOnce() {
        let tracks = songs(30)
        var queue = PlaybackQueue.make(tracks: tracks, startingAt: 4, shuffled: false, source: "test")
        queue.insertNext([Song(id: "next", title: "Next")])
        queue.shuffle(keepingCurrent: true)
        #expect(queue.order.sorted() == Array(queue.tracks.indices))
        let ids = pass(queue)
        #expect(ids.count == 31)
        #expect(Set(ids).count == 31)
        #expect(ids.prefix(2) == ["s4", "next"])
    }
}
