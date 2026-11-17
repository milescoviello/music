import CGtk
import Foundation

/// The phone's `PlayShuffleButtons`: Play on the tint, Shuffle on a wash of it, side by
/// side and equally wide, under an album's, a playlist's or an artist's header.
@MainActor
enum PlayShuffle {
    static func make(play: @escaping @MainActor () -> Void, shuffle: @escaping @MainActor () -> Void) -> Box {
        Box.horizontal(spacing: 12) {
            Button("Play", icon: Symbol.icon("play.fill"), "play-pill") { play() }.hexpand()
            Button("Shuffle", icon: Symbol.icon("shuffle"), "shuffle-pill") { shuffle() }.hexpand()
        }.homogeneous()
    }
}
