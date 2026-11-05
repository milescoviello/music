import Foundation
import Testing
@testable import MusicLogic

struct LyricTranslationStoreTests {
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("LyricTranslationStoreTests-\(UUID().uuidString)", isDirectory: true)

    private func store() -> LyricTranslationStore {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return LyricTranslationStore(directory: directory)
    }

    @Test func aTranslationIsKeptForNextTime() async {
        let lines = ["夜の川", "", "Baby"]
        await store().save(["The river at night", nil, "Baby"], of: lines, songID: "a")

        // A later launch reads it from Caches.
        #expect(await store().translations(songID: "a", lines: lines) == ["The river at night", nil, "Baby"])
    }

    @Test func changedLyricsAreNotShownTheOldTranslation() async {
        let store = store()
        await store.save(["The river at night"], of: ["夜の川"], songID: "a")
        #expect(await store.translations(songID: "a", lines: ["夜の川。"]) == nil)
        #expect(await store.translations(songID: "b", lines: ["夜の川"]) == nil)
    }

    @Test func aTranslationThatDoesNotFitItsLinesIsNotKept() async {
        let store = store()
        await store.save(["The river at night"], of: ["夜の川", "罪"], songID: "a")
        #expect(await store.translations(songID: "a", lines: ["夜の川", "罪"]) == nil)
    }
}
