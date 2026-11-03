import CGtk
import Foundation

/// Add to Playlist, the phone's sheet as a dialog: every playlist that can take the songs,
/// each saying how much of them it already has, ticked as many as wanted. One that has them
/// all is shown ticked and cannot be chosen; one that has some is given only the rest.
/// Listed in an order of his own, apart from the Playlists page's: drag a row to move it,
/// so the ones he adds to most are at the top.
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
        /// The playlists as the rows are now, top to bottom.
        var order: [Playlist] = []
    }

    static func show(_ env: Env, _ songs: [Song], suggestedName: String) {
        let store = env.app.playlistStore
        let arrangement = env.app.playlistArrangement
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
        let note = Label("", "dim-label", "caption").wrap()
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
            choice.order = arrangement.forPicker(store.writable)
            var notes: [String] = []
            if choice.order.count > 1 { notes.append("Drag a playlist to move it.") }
            if store.playlists.count > store.writable.count {
                notes.append("Smart playlists fill themselves, so they are not listed.")
            }
            note.text = notes.joined(separator: " ")
            note.isVisible = !notes.isEmpty
            guard !choice.order.isEmpty else {
                list.append(ActionRow(store.isLoading ? "Loading playlists…" : "No playlists yet"))
                return
            }
            for playlist in choice.order {
                let check = CheckButton { on in
                    guard !choice.full.contains(playlist.id) else { return }
                    if on { choice.chosen.insert(playlist.id) } else { choice.chosen.remove(playlist.id) }
                    updateAdd()
                }
                let row = ActionRow(playlist.name, subtitle: "Checking…").prefix(check)
                if choice.order.count > 1 {
                    let handle = Icon("list-drag-handle-symbolic").css("dim-label")
                    gtk_widget_set_cursor_from_name(handle.widget, "grab")
                    row.suffix(handle)
                }
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

        reorderByDragging(list, choice) { from, to, before in
            arrangement.movePicker(from: [from], to: to > from ? to + 1 : to, shown: before)
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
                let targets = choice.order.filter { choice.chosen.contains($0.id) }
                Task { await store.add(songs, to: targets) }
            case "new":
                Menus.newPlaylist(env, songs, suggested: suggestedName)
            default:
                break
            }
        })
        adw_dialog_present(dialog.cast(), Desktop.window)
    }

    /// A row follows the pointer up or down the list, moving a place at a time as it
    /// crosses the next one, and is put down where it is let go. Past GTK's drag
    /// threshold only, so a click still ticks the row. A gesture on the list rather than
    /// drag and drop: this never leaves the dialog, and the row stays itself throughout.
    private static func reorderByDragging(
        _ list: ListBox, _ choice: Choice,
        moved: @escaping @MainActor (_ from: Int, _ to: Int, _ before: [Playlist]) -> Void
    ) {
        let drag = gtk_gesture_drag_new()!
        // Ahead of the rows' own clicks, which it takes over once it is a drag.
        gtk_event_controller_set_propagation_phase(drag.cast(), GTK_PHASE_CAPTURE)
        let reference = WeakReference(list)
        var pressY = 0.0
        var start: (index: Int, before: [Playlist])?
        var current = 0
        /// Where each place in the list ends, measured as the drag begins. Moving rows only
        /// swaps them between places, and the rows' own sizes lag a move until the next
        /// layout, so reading them mid-drag could put a row straight back.
        var bottoms: [Double] = []

        Signal.connect(drag, "drag-begin", point: { _, y in
            pressY = y
            start = nil
        })
        Signal.connect(drag, "drag-update", point: { dx, dy in
            guard let list = reference.value, choice.order.count > 1 else { return }
            let box: OpaquePointer = list.widget.cast()
            if start == nil {
                guard gtk_drag_check_threshold(list.widget, 0, 0, Int32(dx), Int32(dy)) != 0,
                      let pressed = gtk_list_box_get_row_at_y(box, Int32(pressY))
                else { return }
                let index = Int(gtk_list_box_row_get_index(pressed))
                guard choice.order.indices.contains(index) else { return }
                bottoms = choice.order.indices.map { place in
                    var bounds = graphene_rect_t()
                    guard let row = gtk_list_box_get_row_at_index(box, Int32(place)),
                          gtk_widget_compute_bounds(row.cast(), list.widget, &bounds) != 0
                    else { return .infinity }
                    return Double(bounds.origin.y + bounds.size.height)
                }
                gtk_gesture_set_state(drag.cast(), GTK_EVENT_SEQUENCE_CLAIMED)
                start = (index, choice.order)
                current = index
                gtk_widget_add_css_class(pressed.cast(), "dragging")
                gtk_widget_set_cursor_from_name(list.widget, "grabbing")
            }
            // Above the first row or below the last, it goes to that end.
            let y = pressY + dy
            let target = bottoms.firstIndex { y < $0 } ?? bottoms.count - 1
            guard target != current, choice.order.indices.contains(target) else { return }
            list.move(from: current, to: target)
            choice.order.insert(choice.order.remove(at: current), at: target)
            current = target
        })
        Signal.connect(drag, "drag-end", point: { _, _ in
            guard let begun = start, let list = reference.value else { return }
            start = nil
            if let dropped = gtk_list_box_get_row_at_index(list.widget.cast(), Int32(current)) {
                gtk_widget_remove_css_class(dropped.cast(), "dragging")
            }
            gtk_widget_set_cursor(list.widget, nil)
            if current != begun.index { moved(begun.index, current, begun.before) }
        })
        gtk_widget_add_controller(list.widget, drag.cast())
    }
}
