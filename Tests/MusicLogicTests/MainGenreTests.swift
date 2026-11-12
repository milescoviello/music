import Foundation
import Testing

@testable import MusicLogic

/// The genre a song is counted under is the one that describes it, not whichever the tags
/// happened to list first.
struct MainGenreTests {
    @Test func anUmbrellaGenreGivesWayToANarrowerOne() {
        #expect(MainGenre.pick(["Pop", "Rock", "Alternative Metal", "Alternative Pop", "Indie Rock", "Grunge"]) == "Alternative Metal")
        #expect(MainGenre.pick(["Rock", "Hard Rock", "Grunge"]) == "Hard Rock")
        #expect(MainGenre.pick(["Pop", "Synth-Pop"]) == "Synth-Pop")
    }

    @Test func aFirstGenreNothingNarrowsStays() {
        #expect(MainGenre.pick(["Grunge", "Alternative Rock", "Rock"]) == "Grunge")
        #expect(MainGenre.pick(["J-Pop", "Pop"]) == "J-Pop")
        #expect(MainGenre.pick(["Shoegaze"]) == "Shoegaze")
    }

    @Test func videoCategoriesAndNumbersAreNotGenres() {
        #expect(MainGenre.pick(["Music"]) == nil)
        #expect(MainGenre.pick(["Music", "Dream Pop"]) == "Dream Pop")
        #expect(MainGenre.usable(["Beat", "0", "13", "Rock"]) == ["Beat", "Rock"])
        #expect(MainGenre.usable(["Hip\u{00A0}Hop", "hip hop", ""]) == ["Hip Hop"])
    }

    @Test func aSongWithoutTheListFallsBackToItsGenre() throws {
        let json = #"{"id":"s1","title":"Low Tide","genre":"Dream Pop"}"#
        let song = try JSONDecoder().decode(Song.self, from: Data(json.utf8))
        #expect(song.mainGenre == "Dream Pop")
        #expect(song.hasGenre("dream pop"))
    }

    @Test func anAlbumMatchesAnyOfItsGenres() throws {
        let json = #"{"id":"a1","name":"Glass Harbor","genre":"Rock","genres":[{"name":"Rock"},{"name":"Indie Rock"}]}"#
        let album = try JSONDecoder().decode(Album.self, from: Data(json.utf8))
        #expect(album.hasGenre("Indie Rock"))
        #expect(album.mainGenre == "Indie Rock")
        #expect(!album.hasGenre("Pop"))
    }
}
