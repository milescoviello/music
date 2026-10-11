import Foundation
import Testing
@testable import MusicLogic

struct StreamCacheIndexTests {
    private func entry(_ id: String, _ variant: StreamVariant = .original, bytes: Int64, at seconds: TimeInterval) -> StreamCacheIndex.Entry {
        StreamCacheIndex.Entry(
            songID: id,
            variant: variant,
            fileName: "\(id).flac",
            bytes: bytes,
            lastUsed: Date(timeIntervalSince1970: seconds)
        )
    }

    @Test func theOriginalAnswersAnyRequest() {
        #expect(StreamVariant.original.satisfies(.original))
        #expect(StreamVariant.original.satisfies(.mp3(kbps: 128)))
    }

    @Test func aTranscodeAnswersOnlyAnEqualOrLowerRequest() {
        #expect(StreamVariant.mp3(kbps: 320).satisfies(.mp3(kbps: 128)))
        #expect(StreamVariant.mp3(kbps: 128).satisfies(.mp3(kbps: 128)))
        #expect(!StreamVariant.mp3(kbps: 128).satisfies(.mp3(kbps: 320)))
        // A cellular-quality file must never stand in for the original on Wi-Fi.
        #expect(!StreamVariant.mp3(kbps: 320).satisfies(.original))
    }

    @Test func lookupRespectsTheVariantRule() {
        var index = StreamCacheIndex()
        index.insert(entry("a", .mp3(kbps: 128), bytes: 1, at: 0))
        #expect(index.entry(for: "a", satisfying: .mp3(kbps: 96)) != nil)
        #expect(index.entry(for: "a", satisfying: .original) == nil)
        #expect(index.entry(for: "missing", satisfying: .mp3(kbps: 64)) == nil)
    }

    @Test func evictionTakesTheStalestFirstUntilItFits() {
        var index = StreamCacheIndex()
        index.insert(entry("old", bytes: 40, at: 10))
        index.insert(entry("older", bytes: 40, at: 5))
        index.insert(entry("new", bytes: 40, at: 20))

        let evicted = index.evictions(toFit: 80, protecting: []).map(\.songID)
        #expect(evicted == ["older"])
        #expect(index.evictions(toFit: 120, protecting: []).isEmpty)
    }

    @Test func whatIsAboutToPlayIsNeverEvicted() {
        var index = StreamCacheIndex()
        index.insert(entry("next", bytes: 50, at: 1))
        index.insert(entry("after", bytes: 50, at: 2))
        index.insert(entry("stale", bytes: 50, at: 3))

        let evicted = index.evictions(toFit: 50, protecting: ["next", "after"]).map(\.songID)
        // Only the unprotected one goes, even though that leaves it over the limit.
        #expect(evicted == ["stale"])
    }

    @Test func touchingMakesAnEntryTheLastToGo() {
        var index = StreamCacheIndex()
        index.insert(entry("a", bytes: 50, at: 1))
        index.insert(entry("b", bytes: 50, at: 2))
        index.touch("a", at: Date(timeIntervalSince1970: 3))
        #expect(index.evictions(toFit: 50, protecting: []).map(\.songID) == ["b"])
    }

    @Test func replacingReturnsWhatWasThere() {
        var index = StreamCacheIndex()
        index.insert(entry("a", .mp3(kbps: 128), bytes: 10, at: 0))
        let previous = index.insert(entry("a", .original, bytes: 30, at: 1))
        #expect(previous?.variant == .mp3(kbps: 128))
        #expect(index.totalBytes == 30)
    }
}
