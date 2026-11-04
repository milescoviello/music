import CGtk
import Foundation
import Observation

/// Select Tracks, the phone's: a tick box before each of an album's or a playlist's
/// songs, and a bar over them to play, queue, download, favourite or add the chosen ones
/// to a playlist, in the list's order. While selecting, a click on a row ticks it rather
/// than playing it, so a row is plainly one thing or the other.
@MainActor
@Observable
final class TrackSelection {
    private(set) var isActive = false
    private(set) var chosen: Set<String> = []

    func begin() {
        chosen = []
        isActive = true
    }

    func end() {
        isActive = false
        chosen = []
    }

    func set(_ id: String, _ on: Bool) {
        if on { chosen.insert(id) } else { chosen.remove(id) }
    }

    func toggle(_ id: String) { set(id, !chosen.contains(id)) }

    /// In the list's order, not the order they were ticked.
    func songs(from all: [Song]) -> [Song] { all.filter { chosen.contains($0.id) } }

    /// What clicking a row does: tick it while selecting, `otherwise` play.
    func activate(_ song: Song, otherwise: () -> Void) {
        if isActive { toggle(song.id) } else { otherwise() }
    }

    /// `content` with a tick box before it, shown while selecting.
    func row(_ content: Widget, song: Song) -> Widget {
        let check = SelectionCheck(self)
        check.bind(song)
        return Box.horizontal(spacing: 4) {
            check.root
            content.hexpand()
        }
    }

    /// The header bar's Select button.
    func button() -> Widget {
        let button = Button(icon: "selection-mode-symbolic", "flat")
        button.tooltip("Select Tracks")
        button.onClicked { [weak self] in
            guard let self else { return }
            if isActive { end() } else { begin() }
        }
        button.observe { [weak self] in button.setCSS("accent", self?.isActive == true) }
        return button
    }

    /// The bar over the list while selecting.
    func bar(_ env: Env, all: @escaping @MainActor () -> [Song], source: String) -> Widget {
        let app = env.app
        let count = Label("", "heading").xalign(0)
        func chosenSongs() -> [Song] { songs(from: all()) }
        let actions: [Button] = [
            Button("Play", icon: "media-playback-start-symbolic", "suggested-action", "pill") { [weak self] in
                env.play(chosenSongs(), source: source)
                self?.end()
            },
            Button("Play Next", icon: "list-add-symbolic", "pill") { [weak self] in
                app.player.playNext(chosenSongs())
                self?.end()
            },
            Button("Queue", icon: "view-list-symbolic", "pill") { [weak self] in
                app.player.append(chosenSongs())
                self?.end()
            },
            Button("Download", icon: "folder-download-symbolic", "pill") { [weak self] in
                app.downloads.download(chosenSongs())
                self?.end()
            },
            Button("Favourite", icon: "music-heart-symbolic", "pill") { [weak self] in
                for song in chosenSongs() where !app.userState.isStarred(song) { app.userState.toggleStar(song) }
                self?.end()
            },
            Button("Add to Playlist…", icon: "list-add-symbolic", "pill") { [weak self] in
                PlaylistPicker.show(env, chosenSongs(), suggestedName: "")
                self?.end()
            },
        ]
        let done = Button("Done", "flat") { [weak self] in self?.end() }
        let buttons = Box.horizontal(spacing: 6)
        for action in actions { buttons.append(action) }
        let bar = Box.vertical(spacing: 8) {
            Box.horizontal(spacing: 8) {
                count.hexpand()
                done
            }
            ScrolledWindow(buttons, horizontal: GTK_POLICY_AUTOMATIC, vertical: GTK_POLICY_NEVER).propagatesNaturalHeight()
        }
        bar.css("selection-bar")
        bar.observe { [weak self] in
            guard let self else { return }
            bar.isVisible = isActive
            count.text = chosen.isEmpty ? "Select tracks" : "\(chosen.count) selected"
            for action in actions { action.isSensitive = !chosen.isEmpty }
        }
        return bar
    }
}

/// A row's tick box, rebound as a long list's rows are reused.
@MainActor
final class SelectionCheck {
    let root: CheckButton
    private var song: Song?
    private weak var selection: TrackSelection?

    init(_ selection: TrackSelection) {
        self.selection = selection
        let reference = WeakReference<SelectionCheck>(nil)
        root = CheckButton { on in
            guard let check = reference.value, let song = check.song else { return }
            check.selection?.set(song.id, on)
        }
        reference.value = self
        root.valign(GTK_ALIGN_CENTER).margin(horizontal: 6, vertical: 0)
        root.keep(self)
        root.observe {
            guard let check = reference.value, let selection = check.selection else { return }
            _ = selection.chosen
            check.refresh()
        }
    }

    func bind(_ song: Song) {
        self.song = song
        refresh()
    }

    private func refresh() {
        guard let selection else { return }
        root.isVisible = selection.isActive
        let on = song.map { selection.chosen.contains($0.id) } ?? false
        if root.isActive != on { root.isActive = on }
    }
}
