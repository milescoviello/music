import Foundation

/// What a play needs for telling two records of it apart from two plays.
protocol TimedPlay {
    var id: UUID { get }
    var songID: String { get }
    var title: String { get }
    var artist: String { get }
    var at: Date { get }
}

/// Plays from elsewhere, kept once each.
///
/// Another device's plays arrive under their own ids. The server's play log holds every
/// play an app scrobbled as well, under its own row's id, so by id alone the history would
/// count each of those twice. A device and the log both keep the start time the app
/// scrobbled, to the second, so the same song starting at the same moment is the same play.
enum PlayMerge {
    static let sameStart: TimeInterval = 90

    /// `incoming` less what `existing` already holds: the same id, or the same song (by id,
    /// or by title and artist for one whose id changed since) starting at the same moment.
    static func unseen<P: TimedPlay>(_ incoming: [P], among existing: [P]) -> [P] {
        var ids = Set(existing.map(\.id))
        var starts: [String: [Date]] = [:]
        func keys(_ play: P) -> [String] {
            ["id:" + play.songID, "name:" + play.title.lowercased() + "\u{1F}" + play.artist.lowercased()]
        }
        for play in existing {
            for key in keys(play) { starts[key, default: []].append(play.at) }
        }
        var fresh: [P] = []
        for play in incoming where !ids.contains(play.id) {
            let twin = keys(play).contains { key in
                starts[key]?.contains { abs($0.timeIntervalSince(play.at)) <= sameStart } == true
            }
            guard !twin else { continue }
            fresh.append(play)
            ids.insert(play.id)
            for key in keys(play) { starts[key, default: []].append(play.at) }
        }
        return fresh
    }
}

/// The app's own files store a date as Swift does by default, seconds since 2001; the
/// server's answers and sonic's use 1970. Each is read by its own decoder, so the two
/// never meet in the app. A file written by something else with 1970 seconds would read
/// 31 years late, though, and quietly push every play out of every window. Such a date is
/// in the future; read as 1970 seconds it lands in the past, where it belongs.
enum StoredDate {
    static func repaired(_ date: Date, now: Date = .now) -> Date {
        let slack: TimeInterval = 86_400
        guard date.timeIntervalSince(now) > slack else { return date }
        let as1970 = Date(timeIntervalSince1970: date.timeIntervalSinceReferenceDate)
        return as1970.timeIntervalSince(now) <= slack ? as1970 : date
    }
}
