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

    @Test func theAddressIsTheServices() {
        #expect(SonicClient(configuration: .default).url("v1/tracks/abc/about", ["refresh": "1"])?.absoluteString
            == "http://192.168.1.148:8650/v1/tracks/abc/about?refresh=1")
    }
}
