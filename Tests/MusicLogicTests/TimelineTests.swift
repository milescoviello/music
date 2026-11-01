#if canImport(CFFmpeg)
import Foundation
import Testing

@testable import MusicLogic

/// The timeline says which source is heard, not only which song: the same song queued
/// twice in a row is two plays, and by id alone the second one was never seen to start.
///
/// Linux only: this is the desktop's own mixer.
struct TimelineTests {
    private let rate = 48_000

    private func source(_ id: String) -> TrackSource {
        let location = MediaLocation(url: URL(fileURLWithPath: "/nonexistent/\(id).flac"), mimeType: nil, isLocal: true)
        return TrackSource(song: Song(id: id, title: id), location: location, rate: rate, chain: nil)
    }

    @Test func theSameSongTwiceInARowIsTwoSources() {
        let first = source("a")
        let second = source("a")
        let step = 1 / Double(rate)
        let end = Int64(rate * 180)
        let timeline = Timeline()
        timeline.append(frame: 0, source: first, position: 0, step: step)
        timeline.append(frame: end, source: second, position: 0, step: step)

        let before = timeline.reading(at: end - 100)
        let after = timeline.reading(at: end + 100)
        #expect(first.serial != second.serial)
        #expect(before?.serial == first.serial)
        #expect(after?.serial == second.serial)
        #expect(after?.songID == "a")
    }

    @Test func silenceIsNoSource() {
        let timeline = Timeline()
        timeline.append(frame: 0, source: nil, position: 0, step: 0)
        #expect(timeline.reading(at: 10)?.serial == 0)
        #expect(timeline.reading(at: 10)?.songID == nil)
    }
}
#endif
