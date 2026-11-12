import Foundation
import Testing
@testable import MusicLogic

@Suite("One copy of each recording")
struct OneCopyEachTests {
    private func song(_ id: String, _ title: String, album: String = "Low Tide", albumID: String) -> Song {
        var song = Song(id: id, title: title)
        song.artist = "The Lanterns"
        song.album = album
        song.albumId = albumID
        return song
    }

    @Test func theOtherLibrarysCopyIsLeftOut() {
        let songs = [
            song("a1", "Glass Harbor", albumID: "mine"), song("b1", "Pale Orchid", albumID: "mine"),
            song("a2", "Glass Harbor", albumID: "theirs"), song("c1", "Mira", albumID: "mine"),
        ]
        let (kept, index) = PlaybackQueue.oneCopyEach(songs, startingAt: 3)
        #expect(kept.map(\.id) == ["a1", "b1", "c1"])
        #expect(index == 2)
        // Started on the copy left out: the one kept plays instead.
        #expect(PlaybackQueue.oneCopyEach(songs, startingAt: 2).index == 0)
    }

    @Test func whatIsMeantTwiceStays() {
        // The same id twice, and two tracks of one album that share a name.
        let songs = [song("a1", "Glass Harbor", albumID: "mine"), song("a1", "Glass Harbor", albumID: "mine"),
                     song("i1", "Intro", albumID: "mine"), song("i2", "Intro", albumID: "mine")]
        #expect(PlaybackQueue.oneCopyEach(songs, startingAt: 0).songs.map(\.id) == ["a1", "a1", "i1", "i2"])
    }

    @Test func autoplayDoesNotAddTheCopyOfAQueuedSong() {
        let queued = song("a1", "Glass Harbor", albumID: "mine")
        let candidates = [song("a2", "Glass Harbor", albumID: "theirs"), song("b1", "Pale Orchid", albumID: "mine"),
                          song("b2", "Pale Orchid", albumID: "theirs")]
        let picked = AutoplayRules.fresh(candidates, queued: [queued.id], avoided: [],
                                         queuedRecordings: [MixEngine.identity(queued)], limit: 5)
        #expect(picked.map(\.id) == ["b1"])
        // An album is kept whole.
        #expect(AutoplayRules.fresh(candidates, queued: [], avoided: [], limit: 5).count == 3)
    }

    @Test func abandonedWritesGoOnceADayOld() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("abandoned-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let old = folder.appendingPathComponent(".dat.nosync1A2B.x1"), young = folder.appendingPathComponent(".dat.nosync3C4D.x2")
        let kept = folder.appendingPathComponent("history.json")
        for url in [old, young, kept] { try Data("x".utf8).write(to: url) }
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-2 * 86_400)], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-2 * 86_400)], ofItemAtPath: kept.path)
        Paths.removeAbandonedWrites(in: folder)
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(left == [".dat.nosync3C4D.x2", "history.json"])
    }
}
