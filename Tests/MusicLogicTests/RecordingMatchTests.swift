import Foundation
import Testing

@testable import MusicLogic

/// Which song a play of one the server no longer has is taken to be.
struct RecordingMatchTests {
    private func match(_ title: String, _ artist: String, _ album: String, in candidates: [Song]) -> Song? {
        RecordingMatch.song(title: title, artist: artist, album: album, in: candidates)
    }

    private func song(_ id: String, _ title: String, _ artist: String, _ album: String) -> Song {
        var song = Song(id: id, title: title)
        song.artist = artist
        song.album = album
        song.albumId = "album-\(id)"
        return song
    }

    @Test func theSameAlbumWins() {
        let found = match(
            "All the Quiet Hours", "pine‐204", "Map of the Harbor",
            in: [
                song("live", "All the Quiet Hours", "pine-204", "Live from the Pier"),
                song("studio", "All the Quiet Hours", "pine-204", "Map of the Harbor"),
            ]
        )
        #expect(found?.id == "studio")
    }

    @Test func aSongRetaggedOntoItsAlbumIsFound() {
        let found = match(
            "Velvet Static", "k9lo", "Singles",
            in: [song("new", "Velvet Static", "k9lo", "Thorns and Rivers")]
        )
        #expect(found?.id == "new")
    }

    @Test func twoOtherAlbumsAreNotGuessedBetween() {
        let found = match(
            "Tin Kettle", "Mira Vale", "Singles",
            in: [
                song("a", "Tin Kettle", "Mira Vale", "Brass Orchard"),
                song("b", "Tin Kettle", "Mira Vale", "Live at the Granary"),
            ]
        )
        #expect(found == nil)
    }

    @Test func anotherArtistsSongIsNotTaken() {
        let found = match(
            "Tin Kettle", "Mira Vale", "Brass Orchard",
            in: [song("a", "Tin Kettle", "Calder Bay", "Bright Rooms")]
        )
        #expect(found == nil)
    }

    @Test func punctuationAndCaseDoNotCount() {
        let found = match(
            "Where’s the Lighthouse?", "Pine-204", "Map of the Harbor",
            in: [song("a", "Where's the Lighthouse", "pine‐204", "Map Of The Harbor")]
        )
        #expect(found?.id == "a")
    }
}
