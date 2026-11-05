import Foundation
import Testing

@testable import MusicLogic

/// Heavy Rotation is the songs actually played, most lately first: not the favourite
/// artists' charts, which put songs in it that had never once been played.
struct HeavyRotationTests {
    private let now = Date(timeIntervalSince1970: 1_793_700_000)

    private func copy(
        _ id: String, _ title: String, by artist: String = "Mira Vale", plays: Int, daysAgo: Double?
    ) -> MixEngine.Counted {
        MixEngine.Counted(
            id: id, title: title, artist: artist, plays: plays,
            lastPlayed: daysAgo.map { now.addingTimeInterval(-$0 * 86_400) }
        )
    }

    private func play(_ songID: String, daysAgo: Double) -> MixEngine.Sample {
        MixEngine.Sample(songID: songID, artist: "Mira Vale", at: now.addingTimeInterval(-daysAgo * 86_400))
    }

    @Test func aSongNeverPlayedIsNotInIt() {
        let ranked = MixEngine.heavyRotation(
            counted: [copy("a", "Paper Lanterns", plays: 3, daysAgo: 1), copy("b", "Unheard", plays: 0, daysAgo: nil)],
            plays: [], now: now
        )
        #expect(ranked.map(\.title) == ["Paper Lanterns"])
    }

    /// The library has most songs twice; each copy's plays count towards the one song.
    @Test func bothCopiesOfASongAreOneEntryWithTheirPlaysTogether() {
        let ranked = MixEngine.heavyRotation(
            counted: [
                copy("music", "Paper Lanterns", plays: 60, daysAgo: 30),
                copy("mine", "Paper Lanterns", plays: 75, daysAgo: 3),
                copy("other", "Stuck", plays: 100, daysAgo: 30),
            ],
            plays: [], now: now
        )
        #expect(ranked.count == 2)
        let lanterns = ranked.first { $0.title == "Paper Lanterns" }
        #expect(lanterns?.plays == 135)
        #expect(lanterns?.ids == ["mine", "music"])
        // 135 plays, last played three days ago, beats 100 a month ago.
        #expect(ranked.first?.title == "Paper Lanterns")
    }

    /// On repeat this month beats a big count from long ago.
    @Test func thisMonthsRepeatOutranksAnOldFavourite() {
        let recent = (0..<12).map { play("new", daysAgo: Double($0) * 2) }
        let ranked = MixEngine.heavyRotation(
            counted: [
                copy("old", "Old Favourite", plays: 200, daysAgo: 150),
                copy("new", "On Repeat", plays: 12, daysAgo: 0),
            ],
            plays: recent, now: now
        )
        #expect(ranked.map(\.title) == ["On Repeat", "Old Favourite"])
    }

    @Test func eachPickCarriesOnBelowTheLast() {
        let ranked = (0..<100).map { index in
            MixEngine.Played(
                ids: ["s\(index)"], title: "Song \(index)", artist: "Artist \(index % 20)",
                plays: 100 - index, lastPlayed: now, score: Double(100 - index)
            )
        }
        var generator = MixEngine.DayRandom(day: now, salt: 1)
        let first = MixEngine.pickPlayed(
            ranked, limit: 25, reach: 60, perArtist: 3,
            excludingIDs: [], excludingIdentities: [], using: &generator
        )
        #expect(first.count == 25)
        // Never from further down than the best 60.
        #expect(first.allSatisfy { Int($0.ids[0].dropFirst())! < 60 })

        let used = Set(first.flatMap(\.ids))
        let next = MixEngine.pickPlayed(
            ranked, limit: 25, reach: 60, perArtist: 3,
            excludingIDs: used, excludingIdentities: [], using: &generator
        )
        #expect(Set(next.flatMap(\.ids)).isDisjoint(with: used))
        #expect(next.count == 25)
    }

    @Test func noMoreThanThreeByOneArtist() {
        let ranked = (0..<30).map { index in
            MixEngine.Played(
                ids: ["s\(index)"], title: "Song \(index)", artist: index < 20 ? "Mira Vale" : "Other \(index)",
                plays: 10, lastPlayed: now, score: Double(30 - index)
            )
        }
        var generator = MixEngine.DayRandom(day: now)
        let picked = MixEngine.pickPlayed(
            ranked, limit: 25, reach: 60, perArtist: 3,
            excludingIDs: [], excludingIdentities: [], using: &generator
        )
        #expect(picked.filter { $0.artist == "Mira Vale" }.count == 3)
    }

    /// A song already in a mix today, by another copy, is not picked again.
    @Test func aSongAlreadyUsedByNameIsSkipped() {
        let ranked = [
            MixEngine.Played(ids: ["mine"], title: "Paper Lanterns", artist: "Mira Vale", plays: 9, lastPlayed: now, score: 9),
        ]
        var generator = MixEngine.DayRandom(day: now)
        let picked = MixEngine.pickPlayed(
            ranked, limit: 25, reach: 60, perArtist: 3,
            excludingIDs: [], excludingIdentities: [MixEngine.identity(title: "Paper Lanterns", artist: "Mira Vale")],
            using: &generator
        )
        #expect(picked.isEmpty)
    }
}
