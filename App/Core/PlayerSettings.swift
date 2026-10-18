import Foundation
import Observation

/// Plexamp's player preferences: the quick-skip buttons and how far they jump, whether
/// starting something opens the full player, and how lyrics are read along to.
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
        static let seekbar = "player.seekbar"
        static let background = "player.background"
        static let romanizesLyrics = "lyrics.romanize"
        static let translatesLyrics = "lyrics.translate"
    }

    static let skipOptions = [10, 15, 30, 45]

    /// Plexamp's seekbar styles. Smooth and Bars draw the track's loudness, measured from
    /// the file once it is on the phone; a track still streaming gets the line until then.
    enum SeekbarStyle: String, CaseIterable, Identifiable, Sendable {
        case smooth, bars, line
        var id: String { rawValue }
        var title: String {
            switch self {
            case .smooth: return "Smooth"
            case .bars: return "Bars"
            case .line: return "Line"
            }
        }
    }

    /// Plexamp's player backgrounds.
    enum Background: String, CaseIterable, Identifiable, Sendable {
        case flat, smooth, ultrablur
        var id: String { rawValue }
        var title: String {
            switch self {
            case .flat: return "Flat"
            case .smooth: return "Smooth"
            case .ultrablur: return "Ultrablur"
            }
        }
    }

    var seekbarStyle: SeekbarStyle {
        didSet { UserDefaults.standard.set(seekbarStyle.rawValue, forKey: Key.seekbar) }
    }

    var background: Background {
        didSet { UserDefaults.standard.set(background.rawValue, forKey: Key.background) }
    }

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

    /// Lyrics in another script spelled out in Latin letters beneath each line. Set from
    /// the lyrics screen's own menu, where it is wanted, rather than in Settings.
    var romanizesLyrics: Bool {
        didSet { UserDefaults.standard.set(romanizesLyrics, forKey: Key.romanizesLyrics) }
    }

    /// Lyrics not in English with each line's English translation beneath it, made on the
    /// phone. Set from the lyrics screen's menu too.
    var translatesLyrics: Bool {
        didSet { UserDefaults.standard.set(translatesLyrics, forKey: Key.translatesLyrics) }
    }

    init() {
        let defaults = UserDefaults.standard
        opensPlayerOnPlay = defaults.bool(forKey: Key.opensPlayer)
        // Plexamp's defaults: the smooth curve, over the blurred artwork.
        seekbarStyle = defaults.string(forKey: Key.seekbar).flatMap(SeekbarStyle.init(rawValue:)) ?? .smooth
        background = defaults.string(forKey: Key.background).flatMap(Background.init(rawValue:)) ?? .ultrablur
        showsSkipButtons = defaults.object(forKey: Key.showSkip) as? Bool ?? false
        skipBackSeconds = defaults.object(forKey: Key.skipBack) as? Int ?? 10
        skipForwardSeconds = defaults.object(forKey: Key.skipForward) as? Int ?? 30
        romanizesLyrics = defaults.bool(forKey: Key.romanizesLyrics)
        translatesLyrics = defaults.bool(forKey: Key.translatesLyrics)
    }
}
