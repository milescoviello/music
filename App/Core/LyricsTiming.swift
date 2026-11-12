import Foundation

/// A song's lyrics being timed by hand, before they are saved into its file.
///
/// Two ways, used together. Moving every line at once, for lyrics that are right but early
/// or late as a whole: timed against another release of the song, or one with a longer
/// intro. And timing lines one at a time as they are sung, for lyrics that drift, or that
/// were never timed at all: the line marked next is given the moment it starts, and the
/// mark moves on to the one after.
///
/// Timing a line that already had a time moves every later line by as much, so one tap at
/// the first wrong line carries the rest along with it; tapping each line after that as it
/// comes fixes them one by one.
///
/// A line's words can be changed too, or the line taken out: a typo, a misheard line.
/// Lyrics never timed can then be saved as they are, words only.
struct LyricsTiming: Equatable, Sendable {
    /// The words as they came, for the service to find in the file.
    let original: [String]
    /// Whether they came timed.
    let wasSynced: Bool
    private(set) var lines: [LyricLine]
    /// The line the next tap times. Nil once the last line has been timed.
    private(set) var next: Int?
    /// How far the nudges have moved every line, in milliseconds; later is positive.
    private(set) var shift = 0
    private let startingLines: [LyricLine]
    private var history: [Snapshot] = []

    private struct Snapshot: Equatable, Sendable {
        var lines: [LyricLine]
        var next: Int?
        var shift: Int
    }

    init(_ lyrics: StructuredLyrics) {
        original = lyrics.lines.map(\.value)
        wasSynced = lyrics.synced
        if lyrics.synced {
            // The set's offset goes into the lines, which are saved as plain times: every
            // player reads those. A positive offset comes sooner (`LyricClock`).
            let offset = lyrics.offset ?? 0
            lines = lyrics.lines.map { LyricLine(start: $0.start.map { max(0, $0 - offset) }, value: $0.value) }
            next = nil
        } else {
            // Never timed: the blank lines between verses go, as a timed line has nothing
            // to show for one.
            lines = lyrics.lines
                .filter { !Self.isBlank($0.value) }
                .map { LyricLine(start: nil, value: $0.value) }
            next = lines.isEmpty ? nil : 0
        }
        startingLines = lines
    }

    /// Whether any line has a time: what the highlight follows.
    var isTimed: Bool { lines.contains { $0.start != nil } }
    var timedCount: Int { lines.filter { $0.start != nil }.count }
    /// Every line timed.
    var isComplete: Bool { !lines.isEmpty && lines.allSatisfy { $0.start != nil } }
    var hasChanges: Bool { lines != startingLines }
    /// Something to save, and in a form the file can hold: every line timed, or -- lyrics
    /// that never were -- none, the words alone.
    var canSave: Bool { hasChanges && !lines.isEmpty && (isComplete || (!wasSynced && !isTimed)) }
    var canUndo: Bool { !history.isEmpty }

    /// The line the next tap times. A blank line between verses cannot be marked: it
    /// moves with the lines around it.
    mutating func mark(_ index: Int?) {
        guard let index, lines.indices.contains(index), !Self.isBlank(lines[index].value) else {
            next = nil
            return
        }
        next = index
    }

    /// Every timed line, `milliseconds` later (negative: sooner).
    mutating func nudge(by milliseconds: Int) {
        guard isTimed, milliseconds != 0 else { return }
        remember()
        for index in lines.indices {
            lines[index].start = lines[index].start.map { max(0, $0 + milliseconds) }
        }
        shift += milliseconds
    }

    /// The marked line starts at `milliseconds`; the mark moves to the next line.
    mutating func timeNext(at milliseconds: Int) {
        guard let index = next else { return }
        remember()
        let time = max(0, milliseconds)
        if let old = lines[index].start {
            let moved = time - old
            for later in lines.indices where later > index {
                lines[later].start = lines[later].start.map { max(0, $0 + moved) }
            }
        }
        lines[index].start = time
        // Still in order: nothing before it starts after it, nor after it before it.
        for other in lines.indices where other != index {
            guard let start = lines[other].start else { continue }
            if other < index, start > time { lines[other].start = time }
            if other > index, start < time { lines[other].start = time }
        }
        next = lines.indices.first { $0 > index && !Self.isBlank(lines[$0].value) }
    }

    /// The line's words, changed. Its time stays.
    mutating func edit(_ index: Int, to text: String) {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard lines.indices.contains(index), !words.isEmpty, words != lines[index].value else { return }
        remember()
        lines[index] = LyricLine(start: lines[index].start, value: words)
    }

    /// The line taken out; the mark moves to the one that took its place.
    mutating func delete(_ index: Int) {
        guard lines.indices.contains(index), lines.count > 1 else { return }
        remember()
        lines.remove(at: index)
        if let marked = next {
            if marked > index { next = marked - 1 } else if marked == index { mark(min(index, lines.count - 1)) }
        }
    }

    mutating func undo() {
        guard let last = history.popLast() else { return }
        lines = last.lines
        next = last.next
        shift = last.shift
    }

    /// The lyrics as saved: timed, with no offset of their own, or the words alone.
    func saved(from lyrics: StructuredLyrics) -> StructuredLyrics {
        var saved = lyrics
        saved.synced = isComplete
        saved.offset = nil
        saved.line = lines
        return saved
    }

    /// The line being sung at `milliseconds`: the last one started by then. Untimed lines
    /// are passed over, which a binary search could not do.
    static func current(at milliseconds: Int, in lines: [LyricLine]) -> Int? {
        var found: Int?
        for (index, line) in lines.enumerated() {
            guard let start = line.start else { continue }
            if start > milliseconds { break }
            found = index
        }
        return found
    }

    private mutating func remember() {
        history.append(Snapshot(lines: lines, next: next, shift: shift))
        if history.count > 500 { history.removeFirst() }
    }

    private static func isBlank(_ text: String) -> Bool {
        text.allSatisfy(\.isWhitespace)
    }
}
