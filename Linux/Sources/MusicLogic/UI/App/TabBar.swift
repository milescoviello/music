import CGtk
import Foundation

/// The bottom of the window, as iOS 26 floats it over the page: the mini player, and under
/// it the glass tab bar of Home, Library and Downloads with Search a separate circle beside
/// it. Held to the phone's width however wide the window is, in the middle, so the controls
/// are where they are on the phone.
@MainActor
final class BottomChrome {
    let root: Widget

    init(app: AppState, shell: Shell, navigation: Navigation) {
        let mini = MiniPlayer(app: app)
        let miniSlot = Revealer(mini.root, transition: GTK_REVEALER_TRANSITION_TYPE_SLIDE_UP)
        gtk_revealer_set_transition_duration(miniSlot.widget.cast(), 200)

        var tabButtons: [(Shell.Section, Button, Icon, Label)] = []
        let tabs = Box.horizontal(spacing: 0).homogeneous().css("tab-bar", "glass-surface")
        for section in Shell.Section.barTabs {
            let icon = Icon(Symbol.icon(section.symbol + ".fill"), size: 24).halign(GTK_ALIGN_CENTER)
            let label = Label(section.title, "tab-label").xalign(0.5).halign(GTK_ALIGN_CENTER)
            let content = Box.vertical(spacing: 2) {
                icon
                label
            }.valign(GTK_ALIGN_CENTER)
            if section == .downloads {
                let badge = Label("", "badge", "tab-badge").halign(GTK_ALIGN_END).valign(GTK_ALIGN_START)
                badge.observe {
                    let count = app.downloads.activeCount
                    badge.text = String(count)
                    badge.isVisible = count > 0
                }
                let overlay = Overlay(content)
                overlay.add(badge)
                let button = Button(child: overlay, "tab") { shell.select(section) }
                tabButtons.append((section, button, icon, label))
                tabs.append(button)
            } else {
                let button = Button(child: content, "tab") { shell.select(section) }
                tabButtons.append((section, button, icon, label))
                tabs.append(button)
            }
        }

        let search = Button(icon: Symbol.icon("magnifyingglass"), "search-tab", "glass-surface") { shell.select(.search) }
        search.tooltip("Search")

        let tabsRow = Box.horizontal(spacing: 10) {
            tabs.hexpand()
            search.valign(GTK_ALIGN_CENTER)
        }

        // On Search, iOS 26's bar: the tab bar shrinks to a circle for the tab before, the
        // field takes the rest, and a cross clears it.
        let back = Button(icon: Symbol.icon(navigation.previousTab.symbol + ".fill"), "glass-surface", "search-side") {
            shell.select(navigation.previousTab)
        }
        back.tooltip("Back")
        let clear = Button(icon: Symbol.icon("xmark"), "glass-surface", "search-side") {
            navigation.searchEntry?.text = ""
        }
        clear.tooltip("Clear")
        clear.isVisible = false
        let searchRow = Box.horizontal(spacing: 10)
        searchRow.append(back.valign(GTK_ALIGN_CENTER))
        if let entry = navigation.searchEntry {
            searchRow.append(entry.hexpand().valign(GTK_ALIGN_CENTER))
            Signal.connect(entry.widget, "search-changed") { clear.isVisible = !entry.text.isEmpty }
        }
        searchRow.append(clear.valign(GTK_ALIGN_CENTER))
        let row = Stack(transition: GTK_STACK_TRANSITION_TYPE_CROSSFADE)
        row.add(tabsRow, name: "tabs")
        row.add(searchRow, name: "search")
        let column = Box.vertical(spacing: 8) {
            miniSlot
            row
        }.css("bottom-chrome")
        let clamp = Clamp(column, maximum: 480, threshold: 480)
        clamp.valign(GTK_ALIGN_END).margins(bottom: 10, start: 12, end: 12)
        root = clamp

        root.observe {
            let current = navigation.section
            for (section, button, _, _) in tabButtons {
                button.setCSS("selected", section == current)
            }
            search.setCSS("selected", current == .search)
            row.visibleName = current == .search ? "search" : "tabs"
            back.icon = Symbol.icon(navigation.previousTab.symbol + ".fill")
        }
        root.observe {
            miniSlot.isRevealed = app.player.hasQueue && app.player.currentSong != nil
        }
    }
}

/// The phone's mini player: the cover, the title, pause and next, in a glass capsule with
/// the song's progress along its bottom edge. A click anywhere else opens the player; a
/// sideways scroll skips, as the phone's sideways swipe does.
@MainActor
final class MiniPlayer {
    let root: Widget

    init(app: AppState) {
        let player = app.player
        let artwork = ArtworkView(app, size: .thumb, side: 40, shape: .thumb)
        let title = Label("", "mini-title").xalign(0).ellipsize().hexpand()
        let remote = Icon(Symbol.icon("desktopcomputer"), size: 14).css("accent")
        let play = Button(icon: Symbol.icon("pause.fill"), "flat", "mini-button") { player.togglePlayPause() }
        let next = Button(icon: Symbol.icon("forward.fill"), "flat", "mini-button") { player.next() }
        play.tooltip("Play")
        next.tooltip("Next")

        let progress = DrawingArea(height: 2) { _, _, _ in }
        progress.css("mini-progress").halign(GTK_ALIGN_START).valign(GTK_ALIGN_END)

        let row = Box.horizontal(spacing: 12) {
            artwork.root
            title
            remote
            play.valign(GTK_ALIGN_CENTER)
            next.valign(GTK_ALIGN_CENTER)
        }.css("mini-player-row")
        let overlay = Overlay(row)
        overlay.add(progress)
        let capsule = Box.vertical(spacing: 0) { overlay }.css("mini-capsule", "glass-surface")
        capsule.onClick { app.navigator.showsPlayer = true }
        gtk_widget_set_cursor_from_name(capsule.widget, "pointer")
        root = capsule

        capsule.observe {
            guard let song = player.currentSong else { return }
            title.text = song.title
            artwork.show(song.coverArt, fallback: song.album ?? song.title)
        }
        capsule.observe {
            play.icon = Symbol.icon(player.isPlaying ? "pause.fill" : "play.fill")
            play.tooltip(player.isPlaying ? "Pause" : "Play")
        }
        capsule.observe {
            remote.isVisible = PlayOn.players?.session != nil
        }
        // A 2-pixel line needs nothing finer than the controller's elapsed tick; its width
        // is a fraction of the capsule's.
        capsule.observe {
            let fraction = player.duration > 0 ? min(max(player.elapsed / player.duration, 0), 1) : 0
            let width = Int32(Double(gtk_widget_get_width(capsule.widget)) * fraction)
            progress.size(width: max(width, 0), height: 2)
        }

        let scroll = gtk_event_controller_scroll_new(GTK_EVENT_CONTROLLER_SCROLL_HORIZONTAL)!
        var accumulated = 0.0
        Signal.connect(scroll, "scroll", scroll: { dx, _ in
            accumulated += dx
            if accumulated > 3 {
                accumulated = 0
                player.next()
            } else if accumulated < -3 {
                accumulated = 0
                player.previous()
            }
            return true
        })
        gtk_widget_add_controller(capsule.widget, scroll)
    }
}
