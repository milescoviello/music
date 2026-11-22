import Foundation
import Testing
@testable import MusicLogic

/// What the apps do with no server: Autoplay from the songs on this device, lyric search over
/// the lyrics kept with them, and the lyrics kept for songs the stream cache holds.
@Suite("Offline")
struct OfflineTests {
    private func song(_ id: String, _ title: String, artist: String, genre: String? = nil) -> Song {
        var song = Song(id: id, title: title)
        song.artist = artist
        song.genre = genre
        return song
    }

    private struct Fixed: RandomNumberGenerator {
        var state: UInt64 = 7
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            return state
        }
    }

    @Test func offlineAutoplayPicksTheArtistThenTheGenreThenTheRest() {
        let last = song("now", "Lantern", artist: "Glass Harbor", genre: "Indie Rock")
        let here = [
            song("x", "Far Away", artist: "Mira Vale", genre: "Jazz"),
            song("g", "Pale Light", artist: "The Lanterns", genre: "Indie Rock"),
            song("a", "Undertow", artist: "Glass Harbor", genre: "Indie Rock"),
            song("now", "Lantern", artist: "Glass Harbor", genre: "Indie Rock"),
        ]
        var generator = Fixed()
        let picked = OfflinePicks.pick(from: here, after: last, queued: ["now"], recent: [], limit: 10, using: &generator)
        #expect(picked.map(\.id) == ["a", "g", "x"])
    }

    @Test func offlineAutoplayPutsRecentPicksLastAndOneCopyOfARecording() {
        let last = song("now", "Lantern", artist: "Glass Harbor")
        let here = [
            song("a", "Undertow", artist: "Glass Harbor"),
            song("a2", "Undertow", artist: "Glass Harbor"),
            song("b", "Tidewater", artist: "Glass Harbor"),
        ]
        var generator = Fixed()
        let picked = OfflinePicks.pick(from: here, after: last, queued: [], recent: ["b"], limit: 10, using: &generator)
        #expect(picked.map(\.id) == ["a", "b"])
        #expect(OfflinePicks.pick(from: here, after: last, queued: [], recent: [], limit: 1, using: &generator).count == 1)
    }

    @Test func lyricSearchFindsALineWithEveryWord() {
        let lyrics = [StructuredLyrics(lang: "eng", synced: true, line: [
            LyricLine(start: 0, value: "Out past the harbor lights"),
            LyricLine(start: 1_000, value: "We count the boats along the shore"),
        ])]
        let songs = [(song: song("a", "Undertow", artist: "Glass Harbor"), lyrics: lyrics)]
        #expect(KeptLyricsSearch.matches("boats shore", in: songs).map(\.line) == ["We count the boats along the shore"])
        #expect(KeptLyricsSearch.matches("Harbor, lights!", in: songs).map(\.line) == ["Out past the harbor lights"])
        #expect(KeptLyricsSearch.matches("boats lights", in: songs).isEmpty)
        #expect(KeptLyricsSearch.matches("we", in: songs).isEmpty)
    }

    @Test func aCachedSongsLyricsAreKeptInCachesAndADownloadsWin() async {
        Paths.bootstrap()
        let id = "song-\(UUID().uuidString)"
        let cached = [StructuredLyrics(lang: "eng", synced: false, line: [LyricLine(start: nil, value: "cached")])]
        let downloaded = [StructuredLyrics(lang: "eng", synced: false, line: [LyricLine(start: nil, value: "downloaded")])]
        await LyricsStore.shared.save(cached, for: id, in: .cache)
        #expect(await LyricsStore.shared.place(of: id) == .cache)
        #expect(await LyricsStore.shared.load(songID: id) == cached)
        #expect(FileManager.default.fileExists(atPath: Paths.lyricsFile(songID: id, in: Paths.cachedLyrics).path))
        #expect(!FileManager.default.fileExists(atPath: Paths.lyricsFile(songID: id).path))

        await LyricsStore.shared.save(downloaded, for: id)
        #expect(await LyricsStore.shared.place(of: id) == .download)
        #expect(await LyricsStore.shared.load(songID: id) == downloaded)
        // A cached song lacks what a download would, kept in its own place.
        #expect(await DownloadLyrics.wants(id, readsOnServer: false, in: .cache) == [])
    }
}

@Suite("Overnight sync")
struct OvernightWindowTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    @Test func tonightsOneInTheMorningOrTomorrows() {
        #expect(OvernightWindow.next(after: date(22, 0, 30), calendar: calendar) == date(22, 1))
        #expect(OvernightWindow.next(after: date(22, 16), calendar: calendar) == date(23, 1))
        #expect(OvernightWindow.next(after: date(22, 1), calendar: calendar) == date(23, 1))
    }
}
