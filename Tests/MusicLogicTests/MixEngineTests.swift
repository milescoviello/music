import Foundation
import Testing

@testable import MusicLogic

/// The mixes are the one feature that claims to know something about the person using the
/// app, so the claim had better hold: recent listening has to outweigh old listening, one
/// binge must not own the month, and the same day must always give the same mix.
struct MixEngineTests {
    private func sample(
        _ artist: String,
        daysAgo: Double,
        songID: String = UUID().uuidString,
        genre: String? = nil,
        weight: Double = 1
    ) -> MixEngine.Sample {
        MixEngine.Sample(
            songID: songID,
            artist: artist,
            genre: genre,
            at: Date(timeIntervalSinceNow: -daysAgo * 86_400),
            weight: weight
        )
    }

    @Test func recentListeningOutweighsOldListening() {
        // Three plays a quarter ago against one today: the half-life is 30 days, so the
        // old ones are worth an eighth each and today's still wins.
        let scores = MixEngine.artistScores([
            sample("Now", daysAgo: 0),
            sample("Then", daysAgo: 90),
            sample("Then", daysAgo: 91),
            sample("Then", daysAgo: 92),
        ])
        #expect((scores["Now"] ?? 0) > (scores["Then"] ?? 0))
    }

    @Test func oneDaysBingeIsCappedAtFivePlays() {
        let binge = (0..<20).map { sample("Binge", daysAgo: 1, songID: "s\($0)") }
        let steady = (0..<5).map { sample("Steady", daysAgo: 1, songID: "t\($0)") }

        let scores = MixEngine.artistScores(binge + steady)
        // Twenty plays in an afternoon is one enthusiasm, not four times one.
        #expect(abs((scores["Binge"] ?? 0) - (scores["Steady"] ?? 0)) < 0.0001)
    }

    /// The cold-start path has no play events, only the server's counts.
    @Test func weightedSamplesStandInForCounts() {
        let scores = MixEngine.artistScores([
            sample("Counted", daysAgo: 2, weight: 4),
            sample("Once", daysAgo: 2),
        ])
        #expect((scores["Counted"] ?? 0) > (scores["Once"] ?? 0))
    }

    @Test func rankingBreaksTiesByNameSoItNeverReshuffles() {
        let scores = ["Beta": 1.0, "Alpha": 1.0, "Gamma": 2.0]
        #expect(MixEngine.ranked(scores) == ["Gamma", "Alpha", "Beta"])
    }

    @Test func genresRankSeparatelyFromArtists() {
        let scores = MixEngine.genreScores([
            sample("A", daysAgo: 1, genre: "Shoegaze"),
            sample("B", daysAgo: 1, genre: "Shoegaze"),
            sample("C", daysAgo: 1, genre: "Jazz"),
            sample("D", daysAgo: 1, genre: nil),
        ])
        #expect(MixEngine.ranked(scores, limit: 1) == ["Shoegaze"])
        // A missing genre is not a genre called "".
        #expect(scores[""] == nil)
    }

    @Test func recentlyPlayedSongsAreIdentifiable() {
        let recent = MixEngine.songIDs([
            sample("A", daysAgo: 1, songID: "yesterday"),
            sample("B", daysAgo: 30, songID: "lastMonth"),
        ], playedWithin: 7)

        #expect(recent == ["yesterday"])
    }

    // MARK: - Determinism

    @Test func theSameDayGivesTheSameSequence() {
        let day = Date(timeIntervalSince1970: 1_787_000_000)
        var first = MixEngine.DayRandom(day: day)
        var second = MixEngine.DayRandom(day: day)
        #expect((0..<5).map { _ in first.next() } == (0..<5).map { _ in second.next() })
    }

    @Test func anotherDayAndAnotherMixGiveDifferentSequences() {
        let day = Date(timeIntervalSince1970: 1_787_000_000)
        var today = MixEngine.DayRandom(day: day, salt: 1)
        var tomorrow = MixEngine.DayRandom(day: day.addingTimeInterval(86_400), salt: 1)
        var sameDayOtherMix = MixEngine.DayRandom(day: day, salt: 2)

        let a = today.next()
        #expect(a != tomorrow.next())
        // Otherwise all three mixes would make identical picks from overlapping pools.
        #expect(a != sameDayOtherMix.next())
    }

    /// Every timestamp inside a day has to seed the same generator, or the mix would
    /// change every time it was rebuilt during the day.
    @Test func anyMomentInADaySeedsTheSameGenerator() {
        let morning = Calendar.current.startOfDay(for: .now).addingTimeInterval(3_600)
        let evening = morning.addingTimeInterval(12 * 3_600)
        var first = MixEngine.DayRandom(day: morning)
        var second = MixEngine.DayRandom(day: evening)
        #expect(first.next() == second.next())
    }

    // MARK: - Choosing

    private func song(_ id: String, _ title: String, _ artist: String) -> Song {
        var song = Song(id: id, title: title)
        song.artist = artist
        return song
    }

    @Test func noArtistTakesOverAMix() {
        let candidates = (0..<10).map { song("a\($0)", "Track \($0)", "One Artist") }
            + (0..<10).map { song("b\($0)", "Song \($0)", "Another") }

        var generator = MixEngine.DayRandom(day: .now)
        let chosen = MixEngine.choose(
            from: candidates, limit: 25, perArtist: 3, excluding: [], using: &generator
        )

        #expect(chosen.count == 6)
        #expect(chosen.filter { $0.artist == "One Artist" }.count == 3)
    }

    @Test func tracksAnEarlierMixTookAreSkipped() {
        let candidates = (0..<6).map { song("s\($0)", "Track \($0)", "Artist \($0)") }
        var generator = MixEngine.DayRandom(day: .now)
        let chosen = MixEngine.choose(
            from: candidates, limit: 10, perArtist: 5,
            excluding: ["s0", "s1", "s2"], using: &generator
        )
        #expect(chosen.count == 3)
        #expect(chosen.contains { $0.id == "s0" } == false)
    }

    /// Roughly 40% of this library has a twin across the two music folders, so without
    /// collapsing them a mix shows the same recording twice and looks careless.
    @Test func twoCopiesOfTheSameRecordingCountAsOne() {
        let candidates = [
            song("copy1", "Fern and Feather", "Ollie Brandt"),
            song("copy2", "fern and feather ", "ollie brandt"),
            song("other", "Room of Echoes", "Ollie Brandt"),
        ]
        var generator = MixEngine.DayRandom(day: .now)
        let chosen = MixEngine.choose(
            from: candidates, limit: 10, perArtist: 5, excluding: [], using: &generator
        )
        #expect(chosen.count == 2)
    }
}
