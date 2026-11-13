import Foundation
import Testing
@testable import MusicLogic

/// A downloaded song keeps the lyrics saved with it until the server's copy says otherwise.
@Suite("Kept lyrics")
struct LyricsStoreTests {
    private func lyrics(_ starts: [Int]) -> [StructuredLyrics] {
        [StructuredLyrics(lang: "rus", synced: true, line: starts.enumerated().map {
            LyricLine(start: $1, value: "Line \($0)")
        })]
    }

    @Test func lyricsRetimedOnTheServerReplaceTheKeptCopy() {
        let kept = lyrics([44_950, 48_620])
        let retimed = lyrics([47_980, 51_320])
        #expect(LyricsStore.update(kept: kept, server: retimed) == retimed)
    }

    @Test func theSameLyricsChangeNothing() {
        let kept = lyrics([44_950, 48_620])
        #expect(LyricsStore.update(kept: kept, server: lyrics([44_950, 48_620])) == nil)
    }

    @Test func offlineOrNoneOnTheServerKeepsWhatWorks() {
        let kept = lyrics([44_950, 48_620])
        #expect(LyricsStore.update(kept: kept, server: nil) == nil)
        #expect(LyricsStore.update(kept: kept, server: []) == nil)
    }
}
