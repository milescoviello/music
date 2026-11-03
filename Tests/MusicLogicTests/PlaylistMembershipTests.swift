import Foundation
import Testing

@testable import MusicLogic

/// What Add to Playlist says a playlist already has, and what it leaves out when adding.
struct PlaylistMembershipTests {
    private func song(_ id: String, _ title: String, artist: String = "Radiohead", album: String = "In Rainbows") -> Song {
        var song = Song(id: id, title: title)
        song.artist = artist
        song.album = album
        return song
    }

    @Test func theOtherLibrarysCopyCountsAsAlreadyThere() {
        let mine = song("music-1", "All I Need")
        let theirs = song("my-music-1", "All I Need")
        let held = PlaylistMembership(of: [mine], in: [theirs])
        #expect(held.hasAll)
        #expect(held.summary == "Already added")
        #expect(PlaylistMembership.missing([mine], from: [theirs]).isEmpty)
    }

    @Test func caseAndOuterSpacesDoNotMakeANewRecording() {
        let tagged = song("a", "All I Need ", artist: "radiohead")
        #expect(PlaylistMembership(of: [song("b", "All I Need")], in: [tagged]).hasAll)
    }

    @Test func theSameTitleOnAnotherAlbumIsAnotherSong() {
        let intro = song("a", "Intro", album: "First")
        let other = song("b", "Intro", album: "Second")
        let held = PlaylistMembership(of: [other], in: [intro])
        #expect(held.present == 0)
        #expect(held.summary == nil)
        #expect(PlaylistMembership.missing([other], from: [intro]).map(\.id) == ["b"])
    }

    @Test func somePresentIsCountedAndOnlyTheRestAreAdded() {
        let album = (1...5).map { song("s\($0)", "Track \($0)") }
        let held = PlaylistMembership(of: album, in: [album[1], album[3]])
        #expect(held.present == 2)
        #expect(held.total == 5)
        #expect(!held.hasAll)
        #expect(held.summary == "2 of 5 already added")
        #expect(PlaylistMembership.missing(album, from: [album[1], album[3]]).map(\.id) == ["s1", "s3", "s5"])
    }

    @Test func allPresentSaysSo() {
        let album = (1...3).map { song("s\($0)", "Track \($0)") }
        #expect(PlaylistMembership(of: album, in: album).summary == "All 3 already added")
    }

    @Test func repeatsAmongTheSongsAreAddedOnce() {
        let one = song("a", "Reckoner")
        let copy = song("b", "Reckoner")
        #expect(PlaylistMembership.missing([one, one, copy], from: []).map(\.id) == ["a"])
        #expect(PlaylistMembership(of: [one, copy], in: []).total == 1)
    }

    @Test func nothingAskedIsNeverFull() {
        #expect(!PlaylistMembership(of: [], in: [song("a", "Nude")]).hasAll)
    }
}
