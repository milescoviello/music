import Foundation

/// What a downloaded song's kept lyrics still lack, from its files alone: the check
/// `DownloadExtras` sweeps every download with, kept apart so it can be tested.
enum DownloadLyrics {
    struct Wants: OptionSet, Sendable {
        let rawValue: Int
        static let lyrics = Wants(rawValue: 1 << 0)
        static let words = Wants(rawValue: 1 << 1)
        static let translation = Wants(rawValue: 1 << 2)
        static let readings = Wants(rawValue: 1 << 3)
    }

    /// What a downloaded song lacks, from its files alone.
    static func wants(_ songID: String, readsOnServer: Bool, now: Date = .now) async -> Wants {
        guard let sets = await LyricsStore.shared.load(songID: songID), !sets.isEmpty else {
            return LyricsStore.isMarked(.noLyrics, songID: songID, retry: LyricsStore.lyricsRetry, now: now) ? [] : .lyrics
        }
        guard let shown = StructuredLyrics.shown(from: sets), !shown.lines.isEmpty else { return [] }
        var wants: Wants = []
        let text = shown.lines.map(\.value)

        if shown.synced {
            // An empty list is the service having none: asked again after a while.
            let file = Paths.keptLyricsFile(.words, songID: songID)
            let size = ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.intValue
            if size == nil || (size ?? 0) <= 2 && !LyricsStore.isMarked(.words, songID: songID, retry: LyricsStore.wordsRetry, now: now) {
                wants.insert(.words)
            }
        }

        let language = LyricsLanguage.detect(text, tag: shown.lang)
        if !LyricsLanguage.isEnglish(language), !LyricsLanguage.linesToTranslate(text).isEmpty,
           await LyricTranslationStore.shared.keptWithDownload(songID: songID, lines: text) == nil,
           !LyricsStore.isMarked(.noTranslation, songID: songID, retry: LyricsStore.translationRetry, now: now) {
            wants.insert(.translation)
        }

        if readsOnServer, LyricsLanguage.readsOnServer(language),
           await LyricsStore.shared.readings(songID: songID, lines: text) == nil {
            wants.insert(.readings)
        }
        return wants
    }
}
