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

    private func play(_ title: String, by artist: String = "Panchiko", _ date: Date, minutes: Int = 4) -> Recap.Play {
        Recap.Play(title: title, artist: artist, album: "Ginkgo", genre: "Indie", duration: minutes * 60, at: date)
    }

    @Test func theTopsAndTheTotals() {
        let plays = [
            play("Laputa", at(9, 1)), play("Laputa", at(9, 2)), play("laputa", at(9, 3)),
            play("Kids", by: "MGMT", at(9, 3)),
            play("Old", by: "Last Year", calendar.date(from: DateComponents(year: 2025, month: 12, day: 31))!),
        ]
        let recap = Recap.make(plays, year: 2026, calendar: calendar)
        #expect(recap.plays == 4)
        #expect(recap.minutes == 16)
        #expect(recap.topSongs.first?.name == "Laputa")
        #expect(recap.topSongs.first?.plays == 3)
        #expect(recap.topArtists.map(\.name) == ["Panchiko", "MGMT"])
        #expect(recap.songCount == 2)
    }

    @Test func theLongestRunOfDays() {
        let days = [1, 2, 3, 5, 6, 7, 8, 20]
        let recap = Recap.make(days.map { play("A", at(10, $0)) }, year: 2026, calendar: calendar)
        #expect(recap.longestStreak == 4)
    }

    @Test func theBiggestDayTheHourAndTheMonths() {
        let plays = [
            play("A", at(10, 1, 9)), play("B", at(10, 4, 21), minutes: 30), play("C", at(10, 4, 21)),
            play("D", by: "MGMT", at(11, 2, 21)),
        ]
        let recap = Recap.make(plays, year: 2026, calendar: calendar)
        #expect(recap.biggestDay?.minutes == 34)
        #expect(recap.favouriteHour == 21)
        #expect(recap.months.map(\.month) == [10, 11])
        #expect(recap.months.last?.artist == "MGMT")
        #expect(Recap.hourName(21) == "9 PM")
        #expect(Recap.hourName(0) == "12 AM")
    }

    @Test func nothingPlayedIsEmpty() {
        #expect(Recap.make([], year: 2026).isEmpty)
    }
}
