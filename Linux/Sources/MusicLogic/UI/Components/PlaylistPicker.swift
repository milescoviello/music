import CGtk
import Foundation

/// Add to Playlist, the phone's sheet as a dialog: every playlist that can take the songs,
/// each saying how much of them it already has, ticked as many as wanted. One that has them
/// all is shown ticked and cannot be chosen; one that has some is given only the rest.
///
/// It was a submenu, which closes at the first click, so it added to one playlist only,
/// and is built before it opens, so it could not say what each playlist already had.
@MainActor
enum PlaylistPicker {
    /// What the rows and the Add button share.
    private final class Choice {
        var chosen: Set<String> = []
        /// Playlists that already have every song: ticked, and not choosable.
        var full: Set<String> = []
        var rows: [String: (row: ActionRow, check: CheckButton)] = [:]
    }

    static func show(_ env: Env, _ songs: [Song], suggestedName: String) {
        let store = env.app.playlistStore
        let choice = Choice()
        let subject = songs.count == 1 ? "“\(songs[0].title)”" : "\(songs.count) songs"

        let dialog = adw_alert_dialog_new("Add to Playlist", "Add \(subject) to")!
        let responses: [(String, String, AdwResponseAppearance)] = [
            ("cancel", "Cancel", ADW_RESPONSE_DEFAULT),
            ("new", "New Playlist…", ADW_RESPONSE_DEFAULT),
            ("add", "Add", ADW_RESPONSE_SUGGESTED),
        ]
        for (id, label, appearance) in responses {
            adw_alert_dialog_add_response(dialog.cast(), id, label)
            adw_alert_dialog_set_response_appearance(dialog.cast(), id, appearance)
        }
        adw_alert_dialog_set_close_response(dialog.cast(), "cancel")
        adw_alert_dialog_set_response_enabled(dialog.cast(), "add", 0)

        let list = ListBox()
        let note = Label("Smart playlists fill themselves, so they are not listed.", "dim-label", "caption").wrap()
        let scroller = ScrolledWindow(list).propagatesNaturalHeight()
        gtk_scrolled_window_set_max_content_height(scroller.widget.cast(), 380)
        adw_alert_dialog_set_extra_child(dialog.cast(), Box(spacing: 8) { scroller; note }.widget)
        let alive = list.liveness

        func updateAdd() {
            let count = choice.chosen.count
            adw_alert_dialog_set_response_enabled(dialog.cast(), "add", count == 0 ? 0 : 1)
            adw_alert_dialog_set_response_label(dialog.cast(), "add", count > 1 ? "Add to \(count)" : "Add")
        }

        func songCount(_ playlist: Playlist) -> String {
            let count = playlist.songCount ?? 0
            return "\(count) \(count == 1 ? "song" : "songs")"
        }

        func fill() {
            list.removeAll()
            choice.rows = [:]
            note.isVisible = store.playlists.count > store.writable.count
            guard !store.writable.isEmpty else {
                list.append(ActionRow(store.isLoading ? "Loading playlists…" : "No playlists yet"))
                return
            }
            for playlist in store.writable {
                let check = CheckButton { on in
                    guard !choice.full.contains(playlist.id) else { return }
                    if on { choice.chosen.insert(playlist.id) } else { choice.chosen.remove(playlist.id) }
                    updateAdd()
                }
                let row = ActionRow(playlist.name, subtitle: "Checking…").prefix(check)
                // The whole row toggles, not just the box.
                list.append(row) { check.isActive = !check.isActive }
                choice.rows[playlist.id] = (row, check)
            }
        }

        func readMembership() {
            for playlist in store.writable {
                Task {
                    let entries = await store.entries(of: playlist)
                    guard alive.isAlive, let (row, check) = choice.rows[playlist.id] else { return }
                    guard let entries else {
                        row.subtitle = songCount(playlist)
                        return
                    }
                    let held = PlaylistMembership(of: songs, in: entries)
                    row.subtitle = held.summary ?? songCount(playlist)
                    if held.hasAll {
                        choice.full.insert(playlist.id)
                        choice.chosen.remove(playlist.id)
                        check.isActive = true
                        row.sensitive(false)
                        updateAdd()
                    }
                }
            }
        }

        fill()
        Task {
            await store.loadIfNeeded()
            guard alive.isAlive else { return }
            if choice.rows.isEmpty { fill() }
            readMembership()
        }

        Signal.connect(dialog, "response", pointer: { response in
            guard let response else { return }
            switch String(cString: response.assumingMemoryBound(to: CChar.self)) {
            case "add":
                let targets = store.writable.filter { choice.chosen.contains($0.id) }
                Task { await store.add(songs, to: targets) }
            case "new":
                Menus.newPlaylist(env, songs, suggested: suggestedName)
            default:
                break
            }
        })
        adw_dialog_present(dialog.cast(), Desktop.window)
    }
}
