import Foundation
import Testing
@testable import MusicLogic

struct LibraryFacetsTests {
    private func album(_ id: String, year: Int? = nil, types: [String]? = nil, labels: [String] = [],
                       released: ItemDate? = nil, plays: Int? = nil, played: String? = nil) -> Album {
        var album = Album(id: id, name: id)
        album.year = year
        album.releaseTypes = types
        album.recordLabels = labels.map { NamedItem(name: $0) }
        album.originalReleaseDate = released
        album.playCount = plays
        album.played = played
        return album
    }

    @Test func aDiscographySplitsByReleaseTypeNewestFirst() {
        let groups = LibraryFacets.byReleaseKind([
            album("old", year: 1990), album("new", year: 2001),
            album("ep", year: 1995, types: ["ep"]), album("live", year: 1999, types: ["album", "live"]),
        ])
        #expect(groups.map(\.kind) == [.album, .singleOrEP, .live])
        #expect(groups[0].albums.map(\.id) == ["new", "old"])
    }

    @Test func appearsOnIsWhereTheArtistGuests() {
        var guest = Song(id: "1", title: "Feature")
        guest.albumId = "theirs"
        guest.album = "Their Album"
        guest.artists = [ArtistLink(id: "other", name: "Other"), ArtistLink(id: "me", name: "Me")]
        guest.albumArtists = [ArtistLink(id: "other", name: "Other")]

        var own = Song(id: "2", title: "Mine")
        own.albumId = "mine"
        own.artistId = "me"
        own.albumArtists = [ArtistLink(id: "me", name: "Me")]

        let albums = LibraryFacets.appearsOn([guest, own], artistID: "me", excluding: [])
        #expect(albums.map(\.id) == ["theirs"])
        #expect(albums.first?.artist == "Other")
        // An album already on the artist page is not repeated.
        #expect(LibraryFacets.appearsOn([guest], artistID: "me", excluding: ["theirs"]).isEmpty)
    }

    @Test func labelsAreGroupedBiggestFirst() {
        let labels = LibraryFacets.labels([
            album("a", labels: ["Warp"]), album("b", labels: ["Warp", "XL"]), album("c", labels: [" "]),
        ])
        #expect(labels.map(\.name) == ["Warp", "XL"])
        #expect(labels[0].albums.count == 2)
    }

    @Test func onThisDayFindsAnniversariesRoundOnesFirst() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let today = calendar.date(from: DateComponents(year: 2026, month: 10, day: 17))!
        let found = LibraryFacets.onThisDay([
            album("seven", released: ItemDate(year: 2019, month: 10, day: 17)),
            album("ten", released: ItemDate(year: 2016, month: 10, day: 17)),
            album("other day", released: ItemDate(year: 2016, month: 10, day: 18)),
            album("this year", released: ItemDate(year: 2026, month: 10, day: 17)),
            album("year only", released: ItemDate(year: 2001)),
        ], on: today, calendar: calendar)
        #expect(found.map(\.album.id) == ["ten", "seven"])
        #expect(found.first?.years == 10)
    }

    @Test func bestOfIsThatYearByPlays() {
        let best = LibraryFacets.bestOf(year: 2020, in: [
            album("a", year: 2020, plays: 3), album("b", year: 2020, plays: 9),
            album("c", year: 2021, plays: 50), album("d", year: 2020),
        ])
        #expect(best.map(\.id) == ["b", "a"])
    }

    @Test func notPlayedSinceIsOldFavourites() {
        let cutoff = ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z")!
        let found = LibraryFacets.notPlayedSince(cutoff, in: [
            album("stale", plays: 10, played: "2024-03-01T10:00:00Z"),
            album("recent", plays: 10, played: "2026-06-01T10:00:00Z"),
            album("barely", plays: 1, played: "2020-01-01T10:00:00Z"),
        ])
        #expect(found.map(\.id) == ["stale"])
    }
}
