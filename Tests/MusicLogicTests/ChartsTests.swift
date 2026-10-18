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
        #expect(tracks.first?.id == "a")
        #expect(tracks.first?.plays == 2)
        #expect(tracks.first(where: { $0.id == "b" })?.plays == 1)

        let albums = Charts.topAlbums(plays, in: period, limit: 10)
        #expect(albums.map(\.id) == ["A1", "B1"])
        #expect(albums.first?.plays == 3)

        #expect(Charts.topArtists(plays, in: period, limit: 1).map(\.id) == ["X"])
    }
}
