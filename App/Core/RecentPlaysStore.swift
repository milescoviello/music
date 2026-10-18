import Foundation
import Observation

/// Plexamp's Recent Plays, kept: what was started, most recent first. Separate from the
/// listening history, which is tracks heard; this is things put on.
@MainActor
@Observable
final class RecentPlaysStore {
    private static let key = "recentPlays"

    private(set) var recent: RecentPlays

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let stored = try? JSONDecoder().decode(RecentPlays.self, from: data) {
            recent = stored
        } else {
            recent = RecentPlays()
        }
    }

    func record(_ origin: PlayOrigin?) {
        guard let origin else { return }
        recent.record(origin)
        if let data = try? JSONEncoder().encode(recent) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
