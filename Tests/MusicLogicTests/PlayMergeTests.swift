import Foundation
import Testing

@testable import MusicLogic

/// The server's play log and a device's history hold the same plays under different ids:
/// each is kept once, and a real second play of a song is not mistaken for a copy.
struct PlayMergeTests {
    struct Play: TimedPlay {
        var id = UUID()
        var songID: String
        var title = "Low Tide"
        var artist = "The Lanterns"
        var at: Date
    }

    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func aScrobbledPlayIsKeptOnce() {
        let mine = [Play(songID: "s1", at: start)]
        let log = [Play(songID: "s1", at: start.addingTimeInterval(1)), Play(songID: "s1", at: start.addingTimeInterval(300))]
        let fresh = PlayMerge.unseen(log, among: mine)
        #expect(fresh.map(\.at) == [start.addingTimeInterval(300)])
    }

    @Test func aSongWithANewIDIsKnownByName() {
        let mine = [Play(songID: "old", at: start)]
        #expect(PlayMerge.unseen([Play(songID: "new", at: start.addingTimeInterval(2))], among: mine).isEmpty)
        #expect(PlayMerge.unseen([Play(songID: "new", title: "Pale Orchid", at: start)], among: mine).count == 1)
    }

    @Test func theSameIDTwiceIsOnePlay() {
        let play = Play(songID: "s1", at: start)
        #expect(PlayMerge.unseen([play, play], among: []).count == 1)
        #expect(PlayMerge.unseen([play], among: [play]).isEmpty)
    }
}
