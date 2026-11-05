import Foundation
import Testing

@testable import MusicLogic

/// The year in music adds up: top songs by plays, the two libraries' copies as one, the
/// longest run of days, and only this year's plays.
struct RecapTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }

    private func at(_ month: Int, _ day: Int, _ hour: Int = 21) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }

    private func play(_ title: String, by artist: String = "Mira Vale", _ date: Date, minutes: Int = 4) -> Recap.Play {
        Recap.Play(title: title, artist: artist, album: "Glass Harbor", genre: "Indie", duration: minutes * 60, at: date)
    }

    @Test func theTopsAndTheTotals() {
        let plays = [
            play("Paper Lanterns", at(9, 1)), play("Paper Lanterns", at(9, 2)), play("paper lanterns", at(9, 3)),
            play("Driftwood", by: "Northwind Choir", at(9, 3)),
            play("Old", by: "Last Year", calendar.date(from: DateComponents(year: 2025, month: 12, day: 31))!),
        ]
        let recap = Recap.make(plays, year: 2026, calendar: calendar)
        #expect(recap.plays == 4)
        #expect(recap.minutes == 16)
        #expect(recap.topSongs.first?.name == "Paper Lanterns")
        #expect(recap.topSongs.first?.plays == 3)
        #expect(recap.topArtists.map(\.name) == ["Mira Vale", "Northwind Choir"])
        #expect(recap.songCount == 2)
    }

    @Test func artistsAreRankedByTimeListened() {
        let plays = [play("A", by: "Short", at(9, 1), minutes: 2), play("B", by: "Short", at(9, 2), minutes: 2),
                     play("C", by: "Long", at(9, 3), minutes: 9)]
        let recap = Recap.make(plays, year: 2026, calendar: calendar)
        #expect(recap.topArtists.map(\.name) == ["Long", "Short"])
    }

    @Test func theLongestRunOfDays() {
        let days = [1, 2, 3, 5, 6, 7, 8, 20]
        let recap = Recap.make(days.map { play("A", at(10, $0)) }, year: 2026, calendar: calendar)
        #expect(recap.longestStreak == 4)
    }

    @Test func theBiggestDayTheHourAndTheMonths() {
        let plays = [
            play("A", at(10, 1, 9)), play("B", at(10, 4, 21), minutes: 30), play("C", at(10, 4, 21)),
            play("D", by: "Northwind Choir", at(11, 2, 21)),
        ]
        let recap = Recap.make(plays, year: 2026, calendar: calendar)
        #expect(recap.biggestDay?.minutes == 34)
        #expect(recap.favouriteHour == 21)
        #expect(recap.months.map(\.month) == [10, 11])
        #expect(recap.months.last?.artist == "Northwind Choir")
        #expect(Recap.hourName(21) == "9 PM")
        #expect(Recap.hourName(0) == "12 AM")
    }

    @Test func nothingPlayedIsEmpty() {
        #expect(Recap.make([], year: 2026).isEmpty)
    }
}
