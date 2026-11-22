import Foundation
import Testing
@testable import MusicLogic

/// What a download keeps with its lyrics, and what a sweep finds it still lacks. On disk in
/// the tests' own folder (`Paths.root`), one made-up song id per test.
@Suite("Lyrics kept with downloads")
struct DownloadLyricsTests {
    init() {
        Paths.bootstrap()
    }

    private func id() -> String { "song-\(UUID().uuidString)" }

    private func synced(_ lines: [String], lang: String = "eng") -> [StructuredLyrics] {
        [StructuredLyrics(lang: lang, synced: true, line: lines.enumerated().map {
            LyricLine(start: 1_000 * ($0 + 1), value: $1)
        })]
    }

    private let english = ["I walked along the river at night", "and every light was out", "but I still knew the way home"]
    private let other = ["Der Wind weht über den Fluss", "und alle Lichter sind aus", "doch ich kenne den Weg nach Hause"]

    @Test func aSongWithNothingKeptWantsItsLyrics() async {
        #expect(await DownloadLyrics.wants(id(), readsOnServer: false) == .lyrics)
    }

    @Test func aSongTheServerHadNoneForIsAskedAgainAfterAWeek() async {
        let song = id()
        LyricsStore.mark(.noLyrics, songID: song)
        #expect(await DownloadLyrics.wants(song, readsOnServer: false) == [])
        let later = Date.now.addingTimeInterval(LyricsStore.lyricsRetry + 60)
        #expect(await DownloadLyrics.wants(song, readsOnServer: false, now: later) == .lyrics)
    }

    @Test func lyricsFoundLaterClearTheMark() async {
        let song = id()
        LyricsStore.mark(.noLyrics, songID: song)
        await LyricsStore.shared.save(synced(english), for: song)
        #expect(!LyricsStore.isMarked(.noLyrics, songID: song, retry: LyricsStore.lyricsRetry))
    }

    @Test func syncedEnglishLyricsWantOnlyTheirWordTiming() async {
        let song = id()
        await LyricsStore.shared.save(synced(english), for: song)
        #expect(await DownloadLyrics.wants(song, readsOnServer: false) == .words)

        let words = [SonicClient.WordLine(start: 1_000, end: 2_000, text: english[0],
                                          words: [.init(start: 1_000, text: "I ")])]
        await LyricsStore.shared.saveWords(words, for: song)
        #expect(await LyricsStore.shared.words(songID: song) == words)
        #expect(await DownloadLyrics.wants(song, readsOnServer: false) == [])
    }

    @Test func noWordTimingIsAskedAgainAfterAMonth() async {
        let song = id()
        await LyricsStore.shared.save(synced(english), for: song)
        await LyricsStore.shared.saveWords([], for: song)
        #expect(await DownloadLyrics.wants(song, readsOnServer: false) == [])
        let later = Date.now.addingTimeInterval(LyricsStore.wordsRetry + 60)
        #expect(await DownloadLyrics.wants(song, readsOnServer: false, now: later) == .words)
    }

    @Test func unsyncedLyricsWantNoWordTiming() async {
        let song = id()
        await LyricsStore.shared.save([StructuredLyrics(lang: "eng", synced: false, line: english.map {
            LyricLine(start: nil, value: $0)
        })], for: song)
        #expect(await DownloadLyrics.wants(song, readsOnServer: false) == [])
    }

    @Test func lyricsNotInEnglishWantTheirTranslationUntilOneIsKept() async {
        let song = id()
        await LyricsStore.shared.save(synced(other, lang: "deu"), for: song)
        await LyricsStore.shared.saveWords([], for: song)
        #expect(await DownloadLyrics.wants(song, readsOnServer: false) == .translation)

        // Kept only in Caches, which iOS may purge: still wanted.
        await LyricTranslationStore.shared.save(["The wind blows over the river", nil, nil], of: other, songID: song)
        #expect(await DownloadLyrics.wants(song, readsOnServer: false) == .translation)

        await LyricTranslationStore.shared.save(["The wind blows over the river", nil, nil], of: other, songID: song,
                                                keep: true)
        #expect(await DownloadLyrics.wants(song, readsOnServer: false) == [])
    }

    @Test func noTranslationOnTheServerIsAskedAgainAndChangedLyricsAskAtOnce() async {
        let song = id()
        await LyricsStore.shared.save(synced(other, lang: "deu"), for: song)
        await LyricsStore.shared.saveWords([], for: song)
        LyricsStore.mark(.noTranslation, songID: song)
        #expect(await DownloadLyrics.wants(song, readsOnServer: false) == [])
        let later = Date.now.addingTimeInterval(LyricsStore.translationRetry + 60)
        #expect(await DownloadLyrics.wants(song, readsOnServer: false, now: later) == .translation)

        // Fixed lyrics may have a translation the old ones had none of.
        await LyricsStore.shared.save(synced(other + ["und morgen wieder"], lang: "deu"), for: song)
        #expect(await DownloadLyrics.wants(song, readsOnServer: false) == .translation)
    }

    @Test func theDesktopTellsEnglishFromOtherLatinLetters() {
        #expect(LyricsLanguage.looksEnglish(english + english))
        #expect(!LyricsLanguage.looksEnglish(other + other))
        // Too little to tell.
        #expect(!LyricsLanguage.looksEnglish(["the river"]))
    }

    @Test func readingsAreKeptWithTheirLines() async {
        let song = id()
        let tokens: [[Romanizer.Token]] = [[.init(text: "a", reading: "a")], []]
        await LyricsStore.shared.saveReadings(tokens, of: ["a", "b"], for: song)
        #expect(await LyricsStore.shared.readings(songID: song, lines: ["a", "b"]) == tokens)
        #expect(await LyricsStore.shared.readings(songID: song, lines: ["a", "c"]) == nil)
    }

    @Test func removingADownloadTakesEverythingKeptWithIt() async {
        let song = id()
        await LyricsStore.shared.save(synced(english), for: song)
        await LyricsStore.shared.saveWords([], for: song)
        LyricsStore.mark(.noTranslation, songID: song)
        DownloadCatalogStore.removeKeptLyrics(songID: song)
        for file in Paths.keptLyricsFiles(songID: song) {
            #expect(!FileManager.default.fileExists(atPath: file.path))
        }
    }
}

@Suite("Translations kept with downloads")
struct KeptTranslationTests {
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("KeptTranslationTests-\(UUID().uuidString)", isDirectory: true)

    private func store() -> LyricTranslationStore {
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        let kept = root.appendingPathComponent("kept", isDirectory: true)
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true)
        return LyricTranslationStore(directory: cache, keptDirectory: kept)
    }

    @Test func aDownloadsTranslationOutlivesThePurgedCache() async {
        let lines = ["zorvat mil", "kelu tasa"]
        await store().save(["the far hill", "the near sea"], notes: [nil, "a pun"], engine: "claude", of: lines,
                           songID: "a", keep: true)
        try? FileManager.default.removeItem(at: root.appendingPathComponent("cache", isDirectory: true))

        let kept = await store().kept(songID: "a", lines: lines)
        #expect(kept?.translations == ["the far hill", "the near sea"])
        #expect(kept?.notes == [nil, "a pun"])
        #expect(kept?.isFinal == true)
        #expect(await store().keptWithDownload(songID: "a", lines: lines) != nil)
    }

    @Test func aBetterTranslationReplacesTheDownloadsToo() async {
        let lines = ["zorvat mil"]
        let store = store()
        await store.save(["far hill"], of: lines, songID: "a", keep: true)
        // Saved later without `keep`, by a screen that did not know: the kept one follows.
        await store.save(["the far hill"], engine: "claude", of: lines, songID: "a")
        #expect(await store.keptWithDownload(songID: "a", lines: lines)?.translations == ["the far hill"])
    }

    @Test func aSongNotDownloadedIsKeptInTheCacheOnly() async {
        let lines = ["zorvat mil"]
        await store().save(["the far hill"], of: lines, songID: "a")
        #expect(await store().keptWithDownload(songID: "a", lines: lines) == nil)
        #expect(await store().kept(songID: "a", lines: lines) != nil)
    }

    @Test func theCopyThatFitsTheLinesIsTheOneShown() async {
        await store().save(["the far hill"], of: ["zorvat mil"], songID: "a", keep: true)
        // The cache's is of other lines, written by a build that kept nothing with downloads:
        // the download's still fits, and is the one shown.
        let cacheOnly = LyricTranslationStore(directory: root.appendingPathComponent("cache", isDirectory: true))
        await cacheOnly.save(["something else"], of: ["zorvat mila"], songID: "a")
        #expect(await store().kept(songID: "a", lines: ["zorvat mil"])?.translations == ["the far hill"])
        #expect(await store().kept(songID: "a", lines: ["zorvat mila"])?.translations == ["something else"])
    }

    @Test func translationsArePlacedUnderTheLinesAskedAbout() {
        let lines = ["zorvat mil", "", "Baby", "kelu tasa"]
        let placed = LyricTranslationStore.placed(["the far hill", "baby!", "the near sea"], notes: [nil, "x", "a pun"],
                                                  asked: [0, 2, 3], of: lines)
        // Line 2 only repeats itself, so it shows nothing, and loses its note.
        #expect(placed.lines == ["the far hill", nil, nil, "the near sea"])
        #expect(placed.notes == [nil, nil, nil, "a pun"])
    }
}
