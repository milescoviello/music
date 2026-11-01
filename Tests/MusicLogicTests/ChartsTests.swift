import Foundation
import Testing
@testable import MusicLogic

struct ChartsTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    @Test func aYoungPeriodShowsTheOneBefore() {
        // October 3rd is 6% into the month, under Plexamp's 20%.
        let early = ChartPeriod.current(.month, now: date(2026, 10, 3), calendar: calendar)
        #expect(early.start == date(2026, 9, 1, 0))
        let later = ChartPeriod.current(.month, now: date(2026, 10, 17), calendar: calendar)
        #expect(later.start == date(2026, 10, 1, 0))
    }

    @Test func weeksAreISOWeeks() {
        // Saturday 17 October 2026: its ISO week starts Monday the 12th.
        let week = ChartPeriod.current(.week, now: date(2026, 10, 17), calendar: calendar)
        #expect(week.start == date(2026, 10, 12, 0))
        #expect(week.end == date(2026, 10, 19, 0))
    }

    @Test func seasonsAreMeteorologicalAndCrossTheYear() {
        let winter = ChartPeriod.current(.season, now: date(2027, 1, 20), calendar: calendar)
        #expect(winter.start == date(2026, 12, 1, 0))
        #expect(winter.end == date(2027, 3, 1, 0))
        #expect(winter.title(hemisphere: .north, calendar: calendar) == "Winter 2026")
        #expect(winter.title(hemisphere: .south, calendar: calendar) == "Summer 2026")

        let previous = winter.offset(by: -1, calendar: calendar)
        #expect(previous.start == date(2026, 9, 1, 0))
        #expect(previous.title(calendar: calendar) == "Fall 2026")
    }

    @Test func decadesAndYearsStepCleanly() {
        let decade = ChartPeriod.current(.decade, now: date(2026, 10, 17), calendar: calendar)
        #expect(decade.title(calendar: calendar) == "2020s")
        #expect(decade.offset(by: -1, calendar: calendar).title(calendar: calendar) == "2010s")

        let year = ChartPeriod.current(.year, now: date(2026, 10, 17), calendar: calendar)
        #expect(year.title(calendar: calendar) == "2026")
        #expect(!year.hasNext(now: date(2026, 10, 17)))
        #expect(year.offset(by: -1, calendar: calendar).hasNext(now: date(2026, 10, 17)))
    }

    @Test func chartsCountPlaysInThePeriodOnly() {
        let period = ChartPeriod.current(.year, now: date(2026, 10, 17), calendar: calendar)
        func play(_ id: String, album: String, artist: String, _ when: Date) -> ChartPlay {
            ChartPlay(songID: id, title: id, artist: artist, album: album, albumID: album, artistID: artist, at: when)
        }
        let plays = [
            play("a", album: "A1", artist: "X", date(2026, 3, 1)),
            play("a", album: "A1", artist: "X", date(2026, 4, 1)),
            play("b", album: "B1", artist: "Y", date(2026, 5, 1)),
            play("b", album: "B1", artist: "Y", date(2025, 5, 1)), // last year
            play("c", album: "A1", artist: "X", date(2026, 6, 1)),
        ]
        let tracks = Charts.topTracks(plays, in: period, limit: 10)
        #expect(tracks.first?.songID == "a")
        #expect(tracks.first?.plays == 2)
        #expect(tracks.first(where: { $0.songID == "b" })?.plays == 1)

        let albums = Charts.topAlbums(plays, in: period, limit: 10)
        #expect(albums.map(\.title) == ["A1", "B1"])
        #expect(albums.first?.plays == 3)

        #expect(Charts.topArtists(plays, in: period, limit: 1).map(\.id) == ["X"])
    }

    @Test func albumsOfOneNameByTwoArtistsAreTwoRows() {
        let period = ChartPeriod.current(.year, now: date(2026, 10, 17), calendar: calendar)
        // Plays from before album ids were recorded.
        func play(_ id: String, artist: String, _ when: Date) -> ChartPlay {
            ChartPlay(songID: id, title: id, artist: artist, album: "Greatest Hits", at: when)
        }
        let albums = Charts.topAlbums([
            play("a", artist: "Queen", date(2026, 3, 1)),
            play("a", artist: "Queen", date(2026, 3, 2)),
            play("b", artist: "ABBA", date(2026, 4, 1)),
        ], in: period, limit: 10)
        #expect(albums.map(\.plays) == [2, 1])
        #expect(albums.map(\.subtitle) == ["Queen", "ABBA"])
        #expect(Set(albums.map(\.id)).count == 2)
    }

    @Test func allTimeListsCountAnAlbumsCopiesTogether() {
        func album(_ id: String, _ name: String, _ artistID: String, _ plays: Int) -> Album {
            var album = Album(id: id, name: name)
            album.artistId = artistID
            album.artist = artistID
            album.playCount = plays
            return album
        }
        // The server's Most Played as it stood in November 2026, abridged: each copy in
        // its own place, with its own plays.
        let merged = Charts.mergingCopies([
            album("dm", "D>E>A>T>H>M>E>T>A>L", "panchiko", 857),
            album("ht2", "Hybrid Theory", "linkin park", 367),
            album("ht1", "Hybrid Theory", "linkin park", 339),
            album("cu2", "Currents", "tame impala", 308),
            album("cu1", "Currents", "tame impala", 229),
            album("ok2", "OK Computer", "radiohead", 190),
            album("gh", "Greatest Hits", "queen", 150),
            album("gh2", "Greatest Hits", "abba", 150),
        ])
        #expect(merged.map(\.id) == ["dm", "ht2", "cu2", "ok2", "gh", "gh2"])
        #expect(merged.map(\.playCount) == [857, 706, 537, 190, 150, 150])
    }

    @Test func aSongOrAlbumInBothFoldersIsOneRowWithAllItsPlays() {
        let period = ChartPeriod.current(.year, now: date(2026, 10, 17), calendar: calendar)
        // The two library folders' copies: the same tags, different song and album ids.
        func play(_ songID: String, _ title: String, albumID: String, _ when: Date) -> ChartPlay {
            ChartPlay(songID: songID, title: title, artist: "Tame Impala", album: "Currents",
                      albumID: albumID, artistID: "tame", at: when)
        }
        let plays = [
            play("one-1", "Yes I'm Changing", albumID: "currents-1", date(2026, 3, 1)),
            play("one-1", "Yes I'm Changing", albumID: "currents-1", date(2026, 3, 2)),
            play("two-1", "Yes I'm Changing", albumID: "currents-2", date(2026, 3, 3)),
            play("one-2", "Eventually", albumID: "currents-1", date(2026, 3, 4)),
            play("one-2", "Eventually", albumID: "currents-1", date(2026, 3, 5)),
        ]

        let tracks = Charts.topTracks(plays, in: period, limit: 10)
        #expect(tracks.map(\.title) == ["Yes I'm Changing", "Eventually"])
        #expect(tracks.map(\.plays) == [3, 2])
        // Played from the copy heard last.
        #expect(tracks.first?.songID == "two-1")

        let albums = Charts.topAlbums(plays, in: period, limit: 10)
        #expect(albums.count == 1)
        #expect(albums.first?.plays == 5)
        #expect(albums.first?.albumID == "currents-1")
    }
}
