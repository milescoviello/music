import SwiftUI

/// A song row that actually does something: tap plays the whole list from here,
/// long-press gets the standard menu, swipe queues it.
///
/// It takes the *list* rather than a single song because tapping track 5 of an album
/// has to queue tracks 5-12 as well — a row that only knows about itself can only
/// ever play one song, which is the single most common way a music app feels broken.
struct PlayableSongRow: View {
    @Environment(AppState.self) private var appState
    @Environment(ArtworkStore.self) private var artwork

    let songs: [Song]
    let index: Int
    /// Shown in the player as where the queue came from: an album or playlist name.
    let source: String

    var style: SongRow.Style = .withArtwork
    var showsNavigation = true
    /// Passed straight through to `SongRow`, replacing the duration.
    var trailing: String?
    /// When selecting, a tap ticks the row instead of starting playback.
    var selection: SongSelection?

    private var song: Song { songs[index] }

    var body: some View {
        Group {
            if let selection, selection.isActive {
                selectableRow(selection)
            } else {
                playableRow
            }
        }
        // The next rows' covers, loaded as this one comes into view, so a fast scroll finds
        // them in memory rather than drawing grey squares and filling them in.
        .onAppear {
            guard case .withArtwork = style, index + 1 < songs.count else { return }
            artwork.prefetch(songs[(index + 1)..<min(index + 16, songs.count)].lazy.map(\.coverArt), size: .thumb)
        }
    }

    private func selectableRow(_ selection: SongSelection) -> some View {
        let isChosen = selection.chosen.contains(song.id)

        return Button {
            selection.toggle(song.id)
        } label: {
            HStack(spacing: Metrics.itemSpacing) {
                Image(systemName: isChosen ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isChosen ? Color.appTint : .secondary)
                SongRow(song: song, style: style, isCurrent: false, trailing: trailing)
            }
        }
        .buttonStyle(.plain)
    }

    private var playableRow: some View {
        Button {
            appState.player.play(songs: songs, startingAt: index, source: source)
        } label: {
            SongRow(
                song: song,
                style: style,
                isCurrent: appState.player.currentSong?.id == song.id,
                trailing: trailing
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            SongMenu(song: song, showsNavigation: showsNavigation)
        }
        // Mirrors Music.app: the swipe is the shortcut, the menu is the full set.
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                appState.player.playNext([song])
            } label: {
                Label("Play Next", systemImage: "text.insert")
            }
            .tint(.appTint)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                appState.player.append([song])
            } label: {
                Label("Queue", systemImage: "text.append")
            }
            .tint(.gray)
        }
    }
}
