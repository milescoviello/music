import Foundation
import Testing
@testable import MusicLogic

@Suite("Word timing")
struct WordTimingTests {
    private func timed(_ start: Int, _ words: [(Int, String)]) -> SonicClient.WordLine {
        SonicClient.WordLine(
            start: start, end: start + 2_000, text: words.map(\.1).joined(),
            words: words.map { SonicClient.WordLine.Word(start: $0.0, text: $0.1) }
        )
    }

    @Test func wordsKeepTheirPlaceInTheShownLine() {
        // LRCLIB's lines run 500 ms later than the library's own, which were fixed by hand.
        let theirs = [
            timed(1_500, [(1_500, "First "), (1_900, "light")]),
            timed(4_500, [(4_500, "Over "), (4_800, "the "), (5_000, "harbor")]),
        ]
        let ours = [LyricLine(start: 1_000, value: "First light"), LyricLine(start: 4_000, value: "Over the harbor!")]
        let cues = WordTiming.align(ours, with: theirs)
        #expect(cues[0] == [WordCue(offset: 0, text: "First "), WordCue(offset: 400, text: "light")])
        #expect(cues[1]?.map(\.offset) == [0, 300, 500])
    }

    @Test func aChorusSungTwiceTakesTheNearestTwin() {
        let theirs = [
            timed(1_000, [(1_000, "Glass "), (1_200, "harbor")]),
            timed(9_000, [(9_000, "Glass "), (9_700, "harbor")]),
        ]
        let ours = [LyricLine(start: 1_000, value: "Glass harbor"), LyricLine(start: 9_000, value: "Glass harbor")]
        let cues = WordTiming.align(ours, with: theirs)
        #expect(cues[0]?.last?.offset == 200)
        #expect(cues[1]?.last?.offset == 700)
    }

    @Test func aLineWithNoTwinLightsUpWhole() {
        let cues = WordTiming.align([LyricLine(start: 0, value: "Pale orchid")], with: [timed(0, [(0, "Mira "), (200, "Vale")])])
        #expect(cues.isEmpty)
    }

    @Test func wordsSungSoFar() {
        let cues = [WordCue(offset: 0, text: "a "), WordCue(offset: 300, text: "b")]
        #expect(WordTiming.sung(cues, at: -10) == 0)
        #expect(WordTiming.sung(cues, at: 0) == 1)
        #expect(WordTiming.sung(cues, at: 400) == 2)
    }
}
