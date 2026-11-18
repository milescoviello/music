import Foundation
import Testing
@testable import MusicLogic

struct SongAboutTests {
    @Test func theServicesAnswerDecodes() throws {
        let about = try JSONDecoder().decode(SongAbout.self, from: Data(#"""
        {"id":"s","title":"Parallel Universe","artist":"Red Hot Chili Peppers","album":"Californication",
         "summary":{"text":"About addiction.","basis":"sources"},
         "sections":[{"source":"Genius","heading":"About","text":"The second song.","url":"https://genius.com/song"},
                     {"source":"Wikipedia","heading":"Overview","text":"A single.","url":null}],
         "notes":[{"fragment":"Deep inside of a parallel universe","text":"Addiction's private world.","url":"https://genius.com/1","reviewed":false}],
         "links":[{"name":"Genius","url":"https://genius.com/song"}],
         "released":"June 8, 1999","writers":["Anthony Kiedis","Flea","John Frusciante","Chad Smith","Rick Rubin"]}
        """#.utf8))
        #expect(about.summary?.isReadingOfLyrics == false)
        #expect(about.sections.map(\.id) == ["Genius/About", "Wikipedia/Overview"])
        #expect(about.notes.first?.fragment == "Deep inside of a parallel universe")
        #expect(about.facts == "1999 · Written by Anthony Kiedis, Flea, John Frusciante, Chad Smith and 1 more")
        #expect(!about.isEmpty)
        #expect(!about.unavailable)
    }

    @Test func nothingFoundIsEmptyNotAnError() throws {
        let about = try JSONDecoder().decode(SongAbout.self, from: Data(#"""
        {"id":"s","title":"Obscure","artist":"Nobody","album":"","summary":null,"sections":[],"notes":[],"links":[],"unavailable":true}
        """#.utf8))
        #expect(about.isEmpty)
        #expect(about.unavailable)
        #expect(about.facts == nil)
    }

    @Test func aReadingOfTheLyricsSaysSo() throws {
        let about = try JSONDecoder().decode(SongAbout.self, from: Data(#"""
        {"id":"s","summary":{"text":"A reading.","basis":"lyrics"}}
        """#.utf8))
        #expect(about.summary?.isReadingOfLyrics == true)
        #expect(!about.isEmpty)
    }

    @Test func anAlbumPageShowsTheSummaryElseTheFirstPassage() throws {
        let written = try JSONDecoder().decode(SongAbout.self, from: Data(#"""
        {"id":"al","kind":"album","title":"Currents","artist":"Tame Impala","released":"July 17, 2015",
         "summary":{"text":"About change.","basis":"sources"},
         "sections":[{"source":"Genius","heading":"About","text":"A warm sonic wave.","url":"https://genius.com/a"}],
         "links":[{"name":"Genius","url":"https://genius.com/a"}]}
        """#.utf8))
        #expect(written.preview(of: .album) == .init(text: "About change.", credit: "Written by Claude from the sources."))
        #expect(written.releasedLine == "Released July 17, 2015")
        #expect(written.hasSources)

        let quoted = try JSONDecoder().decode(SongAbout.self, from: Data(#"""
        {"id":"ar","kind":"artist","title":"Panchiko",
         "sections":[{"source":"Wikipedia","heading":"Overview","text":"A band from Nottingham.","url":null}],"links":[]}
        """#.utf8))
        #expect(quoted.preview(of: .artist) == .init(text: "A band from Nottingham.", credit: "From Wikipedia."))
        #expect(quoted.hasSources)

        let nothing = try JSONDecoder().decode(SongAbout.self, from: Data(#"{"id":"x","sections":[],"links":[]}"#.utf8))
        #expect(nothing.preview(of: .album) == nil)
        #expect(!nothing.hasSources)
    }

    @Test func anAlbumSummedUpFromItsSongsSaysSo() throws {
        let about = try JSONDecoder().decode(SongAbout.self, from: Data(#"""
        {"id":"al","summary":{"text":"Songs about the sea.","basis":"songs"}}
        """#.utf8))
        #expect(about.preview(of: .album)?.credit == "Claude's reading of its songs: nothing has been written about this album.")
        #expect(!about.hasSources)
    }

    @Test func albumAndArtistAddresses() {
        let client = SonicClient(configuration: .default)
        #expect(client.url("v1/albums/al/about", ["name": "Currents"])?.absoluteString
            == "http://192.168.1.148:8650/v1/albums/al/about?name=Currents")
        #expect(client.url("v1/artists/ar/about", ["name": "Кино"])?.absoluteString
            == "http://192.168.1.148:8650/v1/artists/ar/about?name=%D0%9A%D0%B8%D0%BD%D0%BE")
    }

    @Test func theAddressIsTheServices() {
        #expect(SonicClient(configuration: .default).url("v1/tracks/abc/about", ["refresh": "1"])?.absoluteString
            == "http://192.168.1.148:8650/v1/tracks/abc/about?refresh=1")
    }
}
