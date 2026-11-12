import Foundation

/// A word of a line, and when it is sung: milliseconds after the line starts.
struct WordCue: Equatable, Sendable {
    let offset: Int
    let text: String
}

/// Lyrics that light up word by word: LRCLIB's word timing for a song, laid over the
/// lyrics the app shows.
///
/// Laid over, not shown instead: the lines shown are the library's own, perhaps timed by
/// hand (`LyricsTiming`), and LRCLIB's may be of another release, a little earlier or later
/// throughout. So each shown line takes the words of LRCLIB's line with the same words --
/// of several, a chorus sung three times, the one nearest in time once the two are put in
/// step -- and its words keep their places within the line, counted from the shown line's
/// start. A line with no such twin has no word timing, and lights up whole as before.
enum WordTiming {
    static func align(_ lines: [LyricLine], with timed: [SonicClient.WordLine]) -> [Int: [WordCue]] {
        let byWords = Dictionary(grouping: timed.indices, by: { key(timed[$0].text) })

        // How far apart the two are, typically: the middle of the gaps between lines whose
        // words appear just once in both.
        var gaps: [Int] = []
        let shownCounts = Dictionary(grouping: lines.indices, by: { key(lines[$0].value) }).mapValues(\.count)
        for line in lines {
            let words = key(line.value)
            guard let start = line.start, !words.isEmpty, shownCounts[words] == 1,
                  let twins = byWords[words], twins.count == 1 else { continue }
            gaps.append(start - timed[twins[0]].start)
        }
        let shift = gaps.isEmpty ? 0 : gaps.sorted()[gaps.count / 2]

        var cues: [Int: [WordCue]] = [:]
        for (index, line) in lines.enumerated() {
            guard let start = line.start, let twins = byWords[key(line.value)], !key(line.value).isEmpty else { continue }
            let twin = twins.min { abs(timed[$0].start + shift - start) < abs(timed[$1].start + shift - start) }!
            let source = timed[twin]
            cues[index] = source.words.map { WordCue(offset: max(0, $0.start - source.start), text: $0.text) }
        }
        return cues
    }

    /// How many of the words are sung `elapsed` milliseconds into the line.
    static func sung(_ cues: [WordCue], at elapsed: Int) -> Int {
        cues.lastIndex { $0.offset <= elapsed }.map { $0 + 1 } ?? 0
    }

    /// Words alone, for comparing: lower case, letters and digits, single spaces.
    static func key(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let kept = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(kept).split(separator: " ").joined(separator: " ")
    }
}
