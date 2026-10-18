import SwiftUI

/// Plexamp's three ways into the queue, for any menu that has songs to offer — a track, an
/// album, a playlist, a selection — so every one of them says the same three things.
///
/// - **Play Next**: straight after the current track.
/// - **Add to Up Next**: after the last thing added, so a run of additions keeps its order.
///   Only shown once something has been added and is still to come.
/// - **Add to Queue**: the very end.
struct QueueInsertItems: View {
    @Environment(AppState.self) private var appState

    let songs: [Song]

    private var player: PlaybackController { appState.player }

    var body: some View {
        Button("Play Next", systemImage: "text.insert") {
            player.playNext(songs)
        }
        if player.canAddToUpNext {
            Button("Add to Up Next", systemImage: "list.bullet.indent") {
                player.addToUpNext(songs)
            }
        }
        Button("Add to Queue", systemImage: "text.append") {
            player.append(songs)
        }
    }
}
