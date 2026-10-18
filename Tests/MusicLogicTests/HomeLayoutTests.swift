import Foundation
import Testing
@testable import MusicLogic

struct HomeLayoutTests {
    @Test func theDefaultShowsEverythingInOrder() {
        #expect(HomeLayout.default.visible == HomeHub.allCases)
    }

    @Test func hidingAndMovingSurviveBeingSaved() {
        var layout = HomeLayout.default
        layout.setVisible(false, .mostPlayed)
        layout.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        let restored = HomeLayout.restored(from: layout.encoded)
        #expect(restored == layout)
        #expect(restored.order.first == .stations)
        #expect(!restored.visible.contains(.mostPlayed))
    }

    @Test func movingDownLandsWhereSwiftUISays() {
        var layout = HomeLayout.default
        // Moving the first to offset 3 puts it after the next two, as `onMove` reports.
        layout.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        #expect(Array(layout.order.prefix(3)) == [.recentPlays, .stations, .madeForYou])
    }

    @Test func aStoredLayoutIsRepairedNotDiscarded() {
        let stored = Data(#"{"order":["favourites","gone","favourites","madeForYou"],"hidden":["gone","stations"]}"#.utf8)
        let layout = HomeLayout.restored(from: stored)
        #expect(Set(layout.order) == Set(HomeHub.allCases))
        #expect(layout.order.count == HomeHub.allCases.count)
        #expect(layout.order.first == .favourites)
        #expect(!layout.isVisible(.stations))
        #expect(HomeLayout.restored(from: Data("junk".utf8)) == .default)
    }
}

struct RecentPlaysTests {
    private func song(_ id: String, album: String? = "a1", albumName: String? = "Album", artist: String = "x") -> Song {
        var song = Song(id: id, title: id)
        song.albumId = album
        song.album = albumName
        song.artistId = artist
        song.artist = "Artist \(artist)"
        return song
    }

    @Test func aWholeAlbumUnderItsNameIsTheAlbum() {
        let origin = PlayOrigin.infer(songs: [song("1"), song("2")], source: "Album", station: nil, playlists: [])
        #expect(origin?.id == "album-a1")
    }

    @Test func aStationIsAlwaysTheStation() {
        let origin = PlayOrigin.infer(songs: [song("1")], source: "Library Radio", station: .library, playlists: [])
        #expect(origin?.id == "station-library")
    }

    @Test func aPlaylistIsFoundByName() {
        let playlists = [Playlist(id: "p", name: "Road Trip")]
        let origin = PlayOrigin.infer(
            songs: [song("1"), song("2", album: "a2")], source: "Road Trip", station: nil, playlists: playlists
        )
        #expect(origin?.id == "playlist-p")
    }

    @Test func oneArtistUnderTheirNameIsTheArtist() {
        let origin = PlayOrigin.infer(
            songs: [song("1"), song("2", album: "a2")], source: "Artist x", station: nil, playlists: []
        )
        #expect(origin?.id == "artist-x")
    }

    @Test func aSearchResultIsNothingToGoBackTo() {
        #expect(PlayOrigin.infer(songs: [song("1"), song("2", album: "a2", artist: "y")], source: "Search", station: nil, playlists: []) == nil)
    }

    @Test func recentPlaysAreMostRecentFirstAndUnique() {
        var recent = RecentPlays()
        let album = PlayOrigin.album(id: "a", name: "A", artist: nil, coverArt: nil)
        recent.record(album)
        recent.record(.station(.library, coverArt: nil))
        recent.record(album)
        #expect(recent.origins.map(\.id) == ["album-a", "station-library"])

        for index in 0..<30 { recent.record(.artist(id: "\(index)", name: "\(index)", coverArt: nil)) }
        #expect(recent.origins.count == RecentPlays.limit)
    }
}
