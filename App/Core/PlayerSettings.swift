import Foundation
import Observation

/// Plexamp's player preferences: the quick-skip buttons and how far they jump, and
/// whether starting something opens the full player.
///
/// Plexamp's defaults: skip buttons hidden for music, back 10 s, forward 30 s; the full
/// player stays closed.
@MainActor
@Observable
final class PlayerSettings {
    private enum Key {
        static let showSkip = "player.showSkip"
        static let skipBack = "player.skipBack"
        static let skipForward = "player.skipForward"
        static let opensPlayer = "player.opensOnPlay"
    }

    static let skipOptions = [10, 15, 30, 45]

    var showsSkipButtons: Bool {
        didSet { UserDefaults.standard.set(showsSkipButtons, forKey: Key.showSkip) }
    }

    var skipBackSeconds: Int {
        didSet { UserDefaults.standard.set(skipBackSeconds, forKey: Key.skipBack) }
    }

    var skipForwardSeconds: Int {
        didSet { UserDefaults.standard.set(skipForwardSeconds, forKey: Key.skipForward) }
    }

    /// Plexamp's Show Full Player: go to the player whenever playback is started.
    var opensPlayerOnPlay: Bool {
        didSet { UserDefaults.standard.set(opensPlayerOnPlay, forKey: Key.opensPlayer) }
    }

    init() {
        let defaults = UserDefaults.standard
        opensPlayerOnPlay = defaults.bool(forKey: Key.opensPlayer)
        showsSkipButtons = defaults.object(forKey: Key.showSkip) as? Bool ?? false
        skipBackSeconds = defaults.object(forKey: Key.skipBack) as? Int ?? 10
        skipForwardSeconds = defaults.object(forKey: Key.skipForward) as? Int ?? 30
    }
}
