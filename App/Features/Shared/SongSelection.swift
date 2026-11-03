import SwiftUI

/// Multi-select for song lists.
///
/// Rolled by hand rather than using `List(selection:)` + `EditMode`, for a concrete
/// reason: these rows are `Button`s, and a button inside a selectable `List` fights the
/// selection gesture -- you get a row that sometimes plays and sometimes ticks. An
/// explicit mode means a row is unambiguously one thing or the other.
@Observable
final class SongSelection {
    var isActive = false
    var chosen: Set<String> = []

    func toggle(_ id: String) {
        if chosen.contains(id) {
            chosen.remove(id)
        } else {
            chosen.insert(id)
        }
    }

    func begin(with id: String? = nil) {
        isActive = true
        chosen = id.map { [$0] } ?? []
    }

    func end() {
        isActive = false
        chosen = []
    }

    func songs(from all: [Song]) -> [Song] {
        // Kept in list order, not selection order: a bulk add to a playlist should
        // preserve the album's running order, not the order things were tapped.
        all.filter { chosen.contains($0.id) }
    }
}

/// The bar that appears while selecting. Actions apply to the whole selection.
struct SelectionToolbar: View {
    @Environment(AppState.self) private var appState
    @Environment(UserStateStore.self) private var userState
    @Environment(DownloadCenter.self) private var downloads
    @Environment(PlaylistStore.self) private var playlists
    @Environment(\.playlistPickerHost) private var pickerHost

    let selection: SongSelection
    let all: [Song]
    let source: String

    private var chosen: [Song] { selection.songs(from: all) }

    var body: some View {
        HStack(spacing: 4) {
            action("Play", "play.fill") {
                appState.player.play(songs: chosen, startingAt: 0, source: source)
            }
            action("Queue", "text.append") {
                appState.player.append(chosen)
            }
            action("Download", "arrow.down.circle") {
                downloads.download(chosen)
            }
            action("Favourite", "heart") {
                for song in chosen where !userState.isStarred(song) {
                    userState.toggleStar(song)
                }
            }

            action("Playlist", "text.badge.plus") {
                playlists.picking = .init(songs: chosen, suggestedName: "", host: pickerHost)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private func action(
        _ title: String,
        _ symbol: String,
        _ perform: @escaping () -> Void
    ) -> some View {
        Button {
            perform()
            selection.end()
        } label: {
            labelStack(title, symbol)
        }
        .buttonStyle(.plain)
        .disabled(chosen.isEmpty)
    }

    private func labelStack(_ title: String, _ symbol: String) -> some View {
        VStack(spacing: 2) {
            Image(systemName: symbol)
                .font(.body)
            Text(title)
                .font(.caption2)
        }
        .foregroundStyle(chosen.isEmpty ? Color.secondary : Color.appTint)
        .frame(maxWidth: .infinity)
        .frame(minHeight: Metrics.minimumTouchTarget)
        .contentShape(Rectangle())
    }
}
