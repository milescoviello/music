import Foundation
import NaturalLanguage
import Observation

/// What the lyrics screen shows beneath each line for a song not in English: the line
/// spelled out in Latin letters.
///
/// Worked out once per song, off the main actor, and kept while the screen is open, so
/// switching it off and on again is instant and nothing is recomputed as lines change.
@MainActor
@Observable
final class LyricsReadAlong {
    /// Romanization by line index, only for lines that have one.
    private(set) var romanized: [Int: String] = [:]
    /// The lyrics' language once it is known, for the menu to name.
    private(set) var language: String?

    @ObservationIgnored private var songID: String?
    @ObservationIgnored private var lines: [String] = []
    @ObservationIgnored private var detection: Task<String?, Never>?
    @ObservationIgnored private var romanization: Task<[String?], Never>?

    /// New lyrics on screen. Called in the same turn that shows them, so a line is never
    /// drawn with the previous song's annotations beneath it.
    func show(_ lyrics: StructuredLyrics, songID: String) {
        guard songID != self.songID else { return }
        self.songID = songID
        lines = lyrics.lines.map(\.value)
        romanized = [:]
        language = nil
        romanization = nil

        let lines = lines
        let tag = lyrics.lang
        detection = Task.detached(priority: .userInitiated) {
            LyricsReadAlong.detectLanguage(lines, tag: tag)
        }
    }

    /// Brings what is shown up to date with the reader's settings.
    func update(romanize: Bool) async {
        guard let songID, let detection else { return }
        let language = await detection.value
        guard songID == self.songID else { return }
        self.language = language

        if romanize, romanization == nil {
            let lines = lines
            let task = Task.detached(priority: .userInitiated) {
                Romanizer.romanize(lines, language: language)
            }
            romanization = task
            let result = await task.value
            guard songID == self.songID else { return }
            romanized = Dictionary(uniqueKeysWithValues: result.enumerated().compactMap { index, line in
                line.map { (index, $0) }
            })
        }
    }

    /// The recognizer reads the whole song at once: a single line is too short to tell
    /// Spanish from Portuguese.
    nonisolated static func detectLanguage(_ lines: [String], tag: String?) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(lines.joined(separator: "\n"))
        let detected = recognizer.dominantLanguage.flatMap { $0 == .undetermined ? nil : $0.rawValue }
        return LyricsLanguage.resolve(lines: lines, tag: tag, detected: detected)
    }
}
