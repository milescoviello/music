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
