import Foundation
import Testing
@testable import MusicLogic

@Suite("Autoplay memory")
struct AutoplayMemoryTests {
    private func song(_ id: String, _ title: String) -> Song {
        var song = Song(id: id, title: title)
        song.artist = "The Lanterns"
        return song
    }

    @Test func lateAddsGoLastNotNowhere() {
        let songs = [song("a", "Glass Harbor"), song("b", "Pale Orchid"), song("c", "Low Tide"), song("d", "Mira")]
        let recent: Set = [MixEngine.identity(songs[0]), MixEngine.identity(songs[2])]
        let picked = AutoplayRules.fresh(songs, queued: [], avoided: [], recent: recent, limit: 3)
        #expect(picked.map(\.id) == ["b", "d", "a"])
        // Enough new ones, and the recent stay out altogether.
        #expect(AutoplayRules.fresh(songs, queued: [], avoided: [], recent: recent, limit: 2).map(\.id) == ["b", "d"])
    }

    @Test func twoWeeksAndTheOtherCopyToo() {
        var memory = AutoplayMemory()
        let start = Date(timeIntervalSince1970: 1_000_000)
        memory.note([song("a", "Glass Harbor")], at: start)
        // The other library's copy, under another id, is the same recording.
        #expect(memory.recent(at: start).contains(MixEngine.identity(song("z", "Glass Harbor"))))
        #expect(memory.recent(at: start.addingTimeInterval(13 * 86_400)).count == 1)
        #expect(memory.recent(at: start.addingTimeInterval(15 * 86_400)).isEmpty)
        memory.note([song("b", "Pale Orchid")], at: start.addingTimeInterval(15 * 86_400))
        #expect(memory.added.count == 1)
    }
}
