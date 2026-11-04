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
            "All the Small Things", "blink‐182", "Enema of the State",
            in: [
                song("live", "All the Small Things", "blink-182", "The Mark, Tom and Travis Show"),
                song("studio", "All the Small Things", "blink-182", "Enema of the State"),
            ]
        )
        #expect(found?.id == "studio")
    }

    @Test func aSongRetaggedOntoItsAlbumIsFound() {
        let found = match(
            "Romantic Homicide", "d4vd", "Singles",
            in: [song("new", "Romantic Homicide", "d4vd", "Petals to Thorns")]
        )
        #expect(found?.id == "new")
    }

    @Test func twoOtherAlbumsAreNotGuessedBetween() {
        let found = match(
            "Creep", "Radiohead", "Singles",
            in: [
                song("a", "Creep", "Radiohead", "Pablo Honey"),
                song("b", "Creep", "Radiohead", "Live at the Astoria"),
            ]
        )
        #expect(found == nil)
    }

    @Test func anotherArtistsSongIsNotTaken() {
        let found = match(
            "Creep", "Radiohead", "Pablo Honey",
            in: [song("a", "Creep", "TLC", "CrazySexyCool")]
        )
        #expect(found == nil)
    }

    @Test func punctuationAndCaseDoNotCount() {
        let found = match(
            "What’s My Age Again?", "Blink-182", "Enema of the State",
            in: [song("a", "What's My Age Again", "blink‐182", "Enema Of The State")]
        )
        #expect(found?.id == "a")
    }
}
