import Foundation
import Testing

@testable import MusicLogic

/// An untyped one-song release is a single, not an album named after its song.
struct ReleaseKindTests {
    private func album(types: [String]?, songs: Int?) -> Album {
        var album = Album(id: "a", name: "Low Tide")
        album.releaseTypes = types
        album.songCount = songs
        return album
    }

    @Test func anUntypedOneSongReleaseIsASingle() {
        #expect(ReleaseKind(album: album(types: [], songs: 1)) == .singleOrEP)
        #expect(ReleaseKind(album: album(types: nil, songs: 1)) == .singleOrEP)
    }

    @Test func typesStillWin() {
        #expect(ReleaseKind(album: album(types: ["album"], songs: 1)) == .album)
        #expect(ReleaseKind(album: album(types: [], songs: 12)) == .album)
        #expect(ReleaseKind(album: album(types: [], songs: nil)) == .album)
        #expect(ReleaseKind(album: album(types: ["soundtrack"], songs: 1)) == .soundtrack)
    }
}
