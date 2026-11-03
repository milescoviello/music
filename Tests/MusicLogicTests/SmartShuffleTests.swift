import Foundation
import Testing

@testable import MusicLogic

/// Smart shuffle is still a shuffle: every song once, in an order that changes, only
/// weighted towards what has not been heard lately and away from one artist twice running.
struct SmartShuffleTests {
    private struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private let now = Date(timeIntervalSince1970: 1_793_700_000)

    private func songs(_ count: Int, artists: Int) -> [Song] {
        (0..<count).map { Song(id: "s\($0)", title: "Song \($0)", artist: "Artist \($0 % artists)") }
    }

    @Test func everySongOnceAndNoArtistTwiceRunningWhileThereIsAChoice() {
        let tracks = songs(40, artists: 5)
        var generator = Seeded(state: 1)
        let order = SmartShuffle.order(Array(tracks.indices), of: tracks, lastPlayed: [:], skipped: [:], now: now, using: &generator)
        #expect(order.sorted() == Array(tracks.indices))
        // Only at the very end can what is left be one artist.
        let repeats = zip(order, order.dropFirst()).filter { tracks[$0].artist == tracks[$1].artist }.count
        #expect(repeats <= 3)
        #expect(zip(order.prefix(30), order.prefix(30).dropFirst()).allSatisfy { tracks[$0].artist != tracks[$1].artist })
    }

    @Test func songsNotHeardLatelyLeanEarly() {
        // Half heard today, half not for months: over many shuffles, the unheard half
        // averages nearer the front.
        let tracks = songs(20, artists: 20)
        var lastPlayed: [String: Date] = [:]
        for track in tracks.prefix(10) { lastPlayed[MixEngine.identity(track)] = now }
        var generator = Seeded(state: 7)
        var heard = 0.0, unheard = 0.0
        for _ in 0..<200 {
            let order = SmartShuffle.order(Array(tracks.indices), of: tracks, lastPlayed: lastPlayed, skipped: [:], now: now, using: &generator)
            for (place, index) in order.enumerated() {
                if index < 10 { heard += Double(place) } else { unheard += Double(place) }
            }
        }
        #expect(unheard < heard)
    }

    @Test func aSkippedSongWeighsLess() {
        #expect(SmartShuffle.weight(daysSincePlayed: 10, skipPenalty: 2) < SmartShuffle.weight(daysSincePlayed: 10, skipPenalty: 0))
        #expect(SmartShuffle.weight(daysSincePlayed: 1, skipPenalty: 0) < SmartShuffle.weight(daysSincePlayed: 50, skipPenalty: 0))
    }
}
