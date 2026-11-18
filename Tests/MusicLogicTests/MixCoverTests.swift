import Foundation
import Testing

@testable import MusicLogic

/// The mix card's four tiles are meant to be four different records. They were told apart
/// by cover id, and Navidrome gives each track its own (`mf-…`) when the art is embedded,
/// so Heavy Rotation showed one band's sleeve twice.
struct MixCoverTests {
    private func song(_ id: String, album: String, albumID: String, artist: String = "Low Orbit Choir") -> Song {
        var song = Song(id: id, title: "Track \(id)")
        song.album = album
        song.albumId = albumID
        song.artist = artist
        song.coverArt = "mf-\(id)"
        return song
    }

    @Test func twoTracksOffOneAlbumAreOneTile() {
        let covers = MixEngine.covers(of: [
            song("1", album: "Copper Skies", albumID: "m", artist: "The Velvet Oranges"),
            song("2", album: "Paper Moons", albumID: "p"),
            song("3", album: "Paper Moons", albumID: "p"),
            song("4", album: "Velvet Hours", albumID: "n", artist: "Quiet Engines"),
        ])

        #expect(covers == ["mf-1", "mf-2", "mf-4"])
    }

    @Test func aTwinCopyOfAnAlbumUnderAnotherIDIsTheSameRecord() {
        let covers = MixEngine.covers(of: [
            song("1", album: "Copper Skies", albumID: "m1", artist: "The Velvet Oranges"),
            song("2", album: "Copper Skies", albumID: "m2", artist: "The Velvet Oranges"),
        ])

        #expect(covers == ["mf-1"])
    }

    @Test func stopsAtFourAlbums() {
        let covers = MixEngine.covers(of: (1...6).map { song("\($0)", album: "Album \($0)", albumID: "a\($0)") })

        #expect(covers == ["mf-1", "mf-2", "mf-3", "mf-4"])
    }

    @Test func tracksWithoutAlbumDetailsStillGetTheirCover() {
        var loose = Song(id: "x", title: "Loose")
        loose.coverArt = "al-x"

        #expect(MixEngine.covers(of: [loose]) == ["al-x"])
    }
}
