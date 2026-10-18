import Foundation
import Observation

/// Plexamp's player preferences: the quick-skip buttons and how far they jump.
///
/// Plexamp's defaults: skip buttons hidden for music, back 10 s, forward 30 s.
@MainActor
@Observable
final class PlayerSettings {
    private enum Key {
        static let showSkip = "player.showSkip"
        static let skipBack = "player.skipBack"
        static let skipForward = "player.skipForward"
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

    init() {
        let defaults = UserDefaults.standard
        showsSkipButtons = defaults.object(forKey: Key.showSkip) as? Bool ?? false
        skipBackSeconds = defaults.object(forKey: Key.skipBack) as? Int ?? 10
        skipForwardSeconds = defaults.object(forKey: Key.skipForward) as? Int ?? 30
    }
}
