import Foundation
import Testing

@testable import MusicLogic

/// A song skipped early, by hand, and not played through since, stops being served; one
/// skip is a mood, two is a pattern, and a full play forgives them.
struct SkipMemoryTests {
    private let now = Date(timeIntervalSince1970: 1_793_700_000)

    private func skip(_ title: String, daysAgo: Double, by artist: String = "Band") -> SkipMemory.Skip {
        SkipMemory.Skip(songID: title, title: title, artist: artist, at: now.addingTimeInterval(-daysAgo * 86_400), position: 4)
    }

    @Test func onlyTheStartOfASongCounts() {
        #expect(SkipMemory.isEarly(position: 3, duration: 240))
        #expect(!SkipMemory.isEarly(position: 45, duration: 240))
        // A 40-second interlude: only its first half.
        #expect(SkipMemory.isEarly(position: 10, duration: 40))
        #expect(!SkipMemory.isEarly(position: 25, duration: 40))
    }

    @Test func twoRecentSkipsLeaveASongOutAndOneDoesNot() {
        let once = SkipMemory.penalties(skips: [skip("A", daysAgo: 1)], plays: [], now: now)
        #expect(SkipMemory.avoided(once).isEmpty)
        let twice = SkipMemory.penalties(skips: [skip("A", daysAgo: 1), skip("A", daysAgo: 2)], plays: [], now: now)
        #expect(SkipMemory.avoided(twice) == [MixEngine.identity(title: "A", artist: "Band")])
    }

    @Test func aFullPlaySinceForgivesTheSkips() {
        let key = MixEngine.identity(title: "A", artist: "Band")
        let penalties = SkipMemory.penalties(
            skips: [skip("A", daysAgo: 5), skip("A", daysAgo: 4)],
            plays: [(identity: key, at: now.addingTimeInterval(-86_400))],
            now: now
        )
        #expect(penalties[key] == nil)
    }

    @Test func oldSkipsFade() {
        let old = SkipMemory.penalties(skips: [skip("A", daysAgo: 90), skip("A", daysAgo: 91)], plays: [], now: now)
        #expect(SkipMemory.avoided(old).isEmpty)
    }

    @Test func skipsLowerASongsPlaceInHeavyRotation() {
        let counted = [
            MixEngine.Counted(id: "a", title: "Skipped", artist: "Band", plays: 40, lastPlayed: now),
            MixEngine.Counted(id: "b", title: "Kept", artist: "Band", plays: 30, lastPlayed: now),
        ]
        let plain = MixEngine.heavyRotation(counted: counted, plays: [], now: now)
        #expect(plain.first?.title == "Skipped")
        let skipped = MixEngine.heavyRotation(
            counted: counted, plays: [],
            skipped: [MixEngine.identity(title: "Skipped", artist: "Band"): 1], now: now
        )
        #expect(skipped.first?.title == "Kept")
    }
}

/// Radio for the mixes keeps near what is played: artists already played first, and no
/// more than a third of a batch from artists never played.
struct TasteRadioTests {
    private func song(_ id: Int, by artist: String) -> Song {
        Song(id: "s\(id)", title: "Song \(id)", artist: artist)
    }

    @Test func atMostAThirdFromArtistsNeverPlayed() {
        // Twelve by four played artists, then strangers: all twelve go in, and strangers
        // only up to a third of 24, so the batch comes out short rather than strange.
        let candidates = (0..<60).map { song($0, by: $0 < 12 ? "Known \($0 % 4)" : "Stranger \($0)") }
        let affinity = Dictionary(uniqueKeysWithValues: (0..<4).map { (MixEngine.artistKey("Known \($0)"), 1.0) })
        var generator = MixEngine.DayRandom(day: .now)
        let picked = MixEngine.pickRadio(
            candidates, affinity: affinity, limit: 24, perArtist: 3,
            excluding: [], usedIdentities: [], using: &generator
        )
        #expect(picked.filter { $0.artist?.hasPrefix("Known") == true }.count == 12)
        #expect(picked.filter { $0.artist?.hasPrefix("Stranger") == true }.count == 8)
    }

    @Test func artistsSkippedALotCountAsUnplayed() {
        let affinity = MixEngine.affinity(
            samples: [MixEngine.Sample(songID: "x", artist: "Band", at: .now)],
            played: [],
            skipped: [MixEngine.identity(title: "One", artist: "Band"): 1, MixEngine.identity(title: "Two", artist: "Band"): 1]
        )
        #expect((affinity[MixEngine.artistKey("Band")] ?? 0) <= 0)
    }
}
