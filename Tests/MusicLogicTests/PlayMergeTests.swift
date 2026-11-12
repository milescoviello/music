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

/// A date written in 1970 seconds into a file the app reads as 2001 seconds is put back,
/// and a real date is left alone.
struct StoredDateTests {
    private let now = Date(timeIntervalSince1970: 1_794_000_000)

    @Test func a1970DateReadAs2001IsRepaired() throws {
        let json = #"{"at": 1790000000}"#
        struct Stamp: Decodable { var at: Date }
        let read = try JSONDecoder().decode(Stamp.self, from: Data(json.utf8)).at
        #expect(read > now)
        #expect(StoredDate.repaired(read, now: now) == Date(timeIntervalSince1970: 1_790_000_000))
    }

    @Test func realDatesStay() {
        let recent = now.addingTimeInterval(-3_600)
        #expect(StoredDate.repaired(recent, now: now) == recent)
        let soon = now.addingTimeInterval(600)
        #expect(StoredDate.repaired(soon, now: now) == soon)
    }

    @Test func aRoundTripKeepsTheDate() throws {
        struct Stamp: Codable, Equatable { var at: Date }
        let stamp = Stamp(at: now)
        let back = try JSONDecoder().decode(Stamp.self, from: JSONEncoder().encode(stamp))
        #expect(StoredDate.repaired(back.at, now: now) == now)
    }
}
