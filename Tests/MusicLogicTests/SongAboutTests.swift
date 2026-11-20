import Foundation
import Testing
@testable import MusicLogic

struct SongAboutTests {
    @Test func theServicesAnswerDecodes() throws {
        let about = try JSONDecoder().decode(SongAbout.self, from: Data(#"""
        {"id":"s","title":"Glass Harbour","artist":"The Velvet Oranges","album":"Harbour Nights",
         "summary":{"text":"About the coast.","basis":"sources"},
         "sections":[{"source":"Genius","heading":"About","text":"The second song.","url":"https://genius.com/song"},
                     {"source":"Wikipedia","heading":"Overview","text":"A single.","url":null}],
         "notes":[{"fragment":"Out past the glass harbour lights","text":"The singer's hometown pier.","url":"https://genius.com/1","reviewed":false}],
         "links":[{"name":"Genius","url":"https://genius.com/song"}],
         "released":"June 8, 1999","writers":["Ada Marsh","Ben Tully","Cleo Ray","Dev Okafor","Eli Stone"]}
        """#.utf8))
        #expect(about.summary?.isReadingOfLyrics == false)
        #expect(about.sections.map(\.id) == ["Genius/About", "Wikipedia/Overview"])
        #expect(about.notes.first?.fragment == "Out past the glass harbour lights")
        #expect(about.facts == "1999 · Written by Ada Marsh, Ben Tully, Cleo Ray, Dev Okafor and 1 more")
        #expect(!about.isEmpty)
        #expect(!about.unavailable)
    }

    @Test func nothingFoundIsEmptyNotAnError() throws {
        let about = try JSONDecoder().decode(SongAbout.self, from: Data(#"""
        {"id":"s","title":"Obscure","artist":"Some Artist","album":"","summary":null,"sections":[],"notes":[],"links":[],"unavailable":true}
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
        {"id":"al","kind":"album","title":"Harbour Nights","artist":"The Velvet Oranges","released":"July 17, 2015",
         "summary":{"text":"About change.","basis":"sources"},
         "sections":[{"source":"Genius","heading":"About","text":"A record about the sea.","url":"https://genius.com/a"}],
         "links":[{"name":"Genius","url":"https://genius.com/a"}]}
        """#.utf8))
        #expect(written.preview(of: .album) == .init(text: "About change.", credit: "Written by Claude from the sources."))
        #expect(written.releasedLine == "Released July 17, 2015")
        #expect(written.hasSources)

        let quoted = try JSONDecoder().decode(SongAbout.self, from: Data(#"""
        {"id":"ar","kind":"artist","title":"Low Orbit Choir",
         "sections":[{"source":"Wikipedia","heading":"Overview","text":"A band from Leeds.","url":null}],"links":[]}
        """#.utf8))
        #expect(quoted.preview(of: .artist) == .init(text: "A band from Leeds.", credit: "From Wikipedia."))
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
        #expect(client.url("v1/albums/al/about", ["name": "Harbour Nights"])?.absoluteString
            == "http://192.168.1.148:8650/v1/albums/al/about?name=Harbour%20Nights")
        #expect(client.url("v1/artists/ar/about", ["name": "Звёздный сад"])?.absoluteString
            == "http://192.168.1.148:8650/v1/artists/ar/about?name=%D0%97%D0%B2%D1%91%D0%B7%D0%B4%D0%BD%D1%8B%D0%B9%20%D1%81%D0%B0%D0%B4")
    }

    @Test func theAddressIsTheServices() {
        #expect(SonicClient(configuration: .default).url("v1/tracks/abc/about", ["refresh": "1"])?.absoluteString
            == "http://192.168.1.148:8650/v1/tracks/abc/about?refresh=1")
    }

    @Test func aFlagFromAnAppDecodes() throws {
        let flagged = try JSONDecoder().decode(SongAbout.self, from: Data(#"""
        {"id":"s","summary":{"text":"About the coast.","basis":"sources"},"flagged":{"at":1795000000.5,"note":"wrong band"}}
        """#.utf8))
        #expect(flagged.flagged == SongAbout.Flag(at: 1_795_000_000.5, note: "wrong band"))

        let noNote = try JSONDecoder().decode(SongAbout.self, from: Data(#"{"id":"s","flagged":{"at":1}}"#.utf8))
        #expect(noNote.flagged?.note == "")

        let none = try JSONDecoder().decode(SongAbout.self, from: Data(#"{"id":"s"}"#.utf8))
        #expect(none.flagged == nil)
        #expect(RecordKind.album.aboutKind == .album)
        #expect(RecordKind.artist.aboutKind == .artist)
    }
}
