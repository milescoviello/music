import Foundation
import Testing
@testable import MusicLogic

/// The OpenSubsonic fields are all optional, and two things depend on that being true:
/// a library cache written before they existed must still decode, and a server that
/// predates them must still produce albums and songs rather than an empty screen.
struct OpenSubsonicModelTests {
    @Test func aSongCachedBeforeTheNewFieldsStillDecodes() throws {
        let legacy = Data(#"{"id":"s1","title":"Let It Happen","duration":467}"#.utf8)
        let song = try JSONDecoder().decode(Song.self, from: legacy)
        #expect(song.id == "s1")
        #expect(song.replayGain == nil)
        #expect(song.artists == nil)
    }

    @Test func replayGainDecodesFromTheServersShape() throws {
        let json = Data(#"""
        {"id":"s1","title":"T",
         "replayGain":{"trackGain":-8.4,"albumGain":-7.9,"trackPeak":0.98,"albumPeak":1.0},
         "albumArtists":[{"id":"ar1","name":"Tame Impala"}],
         "artists":[{"id":"ar2","name":"Guest"}],"artistId":"ar2"}
        """#.utf8)
        let song = try JSONDecoder().decode(Song.self, from: json)
        #expect(song.replayGain?.albumGain == -7.9)
        #expect(song.replayGain?.trackPeak == 0.98)
        // The album artist wins: a guest verse is not a different artist.
        #expect(song.primaryArtistID == "ar1")
    }

    @Test func anAlbumWithNoReleaseTypesIsAnAlbum() {
        let album = Album(id: "a", name: "Currents")
        #expect(album.kind == .album)
    }

    @Test func releaseTypesFileByWhatTheReleaseSoundsLike() {
        func kind(_ types: [String], compilation: Bool? = nil) -> ReleaseKind {
            var album = Album(id: "a", name: "x")
            album.releaseTypes = types
            album.isCompilation = compilation
            return album.kind
        }
        #expect(kind(["single"]) == .singleOrEP)
        #expect(kind(["EP"]) == .singleOrEP)
        #expect(kind(["album", "live"]) == .live)
        #expect(kind(["album", "compilation", "live"]) == .live)
        #expect(kind(["album", "soundtrack"]) == .soundtrack)
        #expect(kind(["album"], compilation: true) == .compilation)
        #expect(kind(["album", "remix"]) == .remix)
        #expect(kind(["album"]) == .album)
        #expect(kind(["broadcast"]) == .other)
    }

    @Test func biographiesLoseTheirReadMoreLink() {
        let raw = #"Tame Impala is the project of Kevin Parker. <a href="https://www.last.fm/music/Tame+Impala">Read more on Last.fm</a>"#
        #expect(ServerText.plain(raw) == "Tame Impala is the project of Kevin Parker.")
        #expect(ServerText.plain("  ") == nil)
        #expect(ServerText.plain(#"<a href="x">Read more</a>"#) == nil)
        #expect(ServerText.plain(nil) == nil)
    }

    @Test func artistInfoWithNothingConfiguredIsEmptyNotAnError() throws {
        let json = Data(#"{"musicBrainzId":"","smallImageUrl":""}"#.utf8)
        let info = try JSONDecoder().decode(ArtistInfo.self, from: json)
        #expect(info.plainBiography == nil)
        #expect(info.similarArtists.isEmpty)
    }
}
