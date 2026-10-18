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
        let lines = ["君の名は", "", "Baby"]
        await store().save(["Your name", nil, "Baby"], of: lines, songID: "a")

        // A later launch reads it from Caches.
        #expect(await store().translations(songID: "a", lines: lines) == ["Your name", nil, "Baby"])
    }

    @Test func changedLyricsAreNotShownTheOldTranslation() async {
        let store = store()
        await store.save(["Your name"], of: ["君の名は"], songID: "a")
        #expect(await store.translations(songID: "a", lines: ["君の名は。"]) == nil)
        #expect(await store.translations(songID: "b", lines: ["君の名は"]) == nil)
    }

    @Test func aTranslationThatDoesNotFitItsLinesIsNotKept() async {
        let store = store()
        await store.save(["Your name"], of: ["君の名は", "罪"], songID: "a")
        #expect(await store.translations(songID: "a", lines: ["君の名は", "罪"]) == nil)
    }
}
