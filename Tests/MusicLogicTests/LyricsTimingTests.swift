import Foundation
import Testing
@testable import MusicLogic

@Suite("Lyrics timing")
struct LyricsTimingTests {
    private func synced(_ starts: [Int], offset: Int? = nil) -> StructuredLyrics {
        StructuredLyrics(
            lang: "eng", offset: offset, synced: true,
            line: starts.enumerated().map { LyricLine(start: $1, value: "Line \($0)") }
        )
    }

    private func starts(_ timing: LyricsTiming) -> [Int?] { timing.lines.map(\.start) }

    @Test func nudgingMovesEveryLine() {
        var timing = LyricsTiming(synced([0, 1_000, 5_000]))
        timing.nudge(by: 300)
        #expect(starts(timing) == [300, 1_300, 5_300])
        timing.nudge(by: -500)
        // Never before the start of the track.
        #expect(starts(timing) == [0, 800, 4_800])
        #expect(timing.shift == -200)
        #expect(timing.hasChanges)
    }

    @Test func theSetsOffsetGoesIntoTheLines() {
        // Positive comes sooner.
        let timing = LyricsTiming(synced([1_000, 3_000], offset: 400))
        #expect(starts(timing) == [600, 2_600])
        #expect(timing.saved(from: synced([1_000, 3_000], offset: 400)).offset == nil)
    }

    @Test func timingAnEarlyLineCarriesTheRestAlong() {
        var timing = LyricsTiming(synced([1_000, 2_000, 3_000, 4_000]))
        timing.mark(1)
        timing.timeNext(at: 2_500)
        #expect(starts(timing) == [1_000, 2_500, 3_500, 4_500])
        #expect(timing.next == 2)
        timing.timeNext(at: 3_200)
        #expect(starts(timing) == [1_000, 2_500, 3_200, 4_200])
        #expect(timing.next == 3)
    }

    @Test func linesStayInOrder() {
        var timing = LyricsTiming(synced([1_000, 2_000, 3_000]))
        timing.mark(2)
        timing.timeNext(at: 500)
        #expect(starts(timing) == [500, 500, 500])
    }

    @Test func untimedLyricsAreTimedOneLineAtATime() {
        let lyrics = StructuredLyrics(synced: false, line: [
            LyricLine(value: "First light"), LyricLine(value: " "), LyricLine(value: "Over the harbor"),
        ])
        var timing = LyricsTiming(lyrics)
        // The blank line between verses is gone, and the first line is marked.
        #expect(timing.lines.map(\.value) == ["First light", "Over the harbor"])
        #expect(timing.original == ["First light", " ", "Over the harbor"])
        #expect(timing.next == 0)
        #expect(!timing.isTimed)
        timing.timeNext(at: 1_200)
        #expect(timing.isTimed)
        #expect(!timing.isComplete)
        #expect(timing.timedCount == 1)
        timing.timeNext(at: 4_000)
        #expect(timing.isComplete)
        #expect(timing.next == nil)
        // Nothing to tap once the last line is timed.
        timing.timeNext(at: 9_000)
        #expect(starts(timing) == [1_200, 4_000])
        let saved = timing.saved(from: lyrics)
        #expect(saved.synced)
        #expect(saved.lines.map(\.start) == [1_200, 4_000])
    }

    @Test func theMarkSkipsBlankLines() {
        var timing = LyricsTiming(StructuredLyrics(synced: true, line: [
            LyricLine(start: 0, value: "One"), LyricLine(start: 2_000, value: ""), LyricLine(start: 4_000, value: "Two"),
        ]))
        timing.mark(1)
        #expect(timing.next == nil)
        timing.mark(0)
        timing.timeNext(at: 500)
        #expect(timing.next == 2)
        // The gap moved with the line before it.
        #expect(starts(timing) == [500, 2_500, 4_500])
    }

    @Test func undoGoesBackOneStep() {
        var timing = LyricsTiming(synced([1_000, 2_000]))
        timing.nudge(by: 100)
        timing.mark(0)
        timing.timeNext(at: 1_500)
        timing.undo()
        #expect(starts(timing) == [1_100, 2_100])
        #expect(timing.next == 0)
        timing.undo()
        #expect(starts(timing) == [1_000, 2_000])
        #expect(!timing.canUndo)
        #expect(!timing.hasChanges)
    }

    @Test func theLineBeingSung() {
        let lines = [LyricLine(start: 1_000, value: "a"), LyricLine(start: 3_000, value: "b"), LyricLine(value: "c")]
        #expect(LyricsTiming.current(at: 500, in: lines) == nil)
        #expect(LyricsTiming.current(at: 1_000, in: lines) == 0)
        #expect(LyricsTiming.current(at: 9_000, in: lines) == 1)
    }
}
