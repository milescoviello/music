import CGtk
import Foundation

/// The play queue, Plexamp's way: what is coming up, and one tab over what already
/// played, so a track half-heard is a click away. Autoplay's choices sit at the end of Up
/// Next, shown as what they are.
@MainActor
final class QueuePane {
    let root: Box
    private let env: Env
    private let list = ListBox(boxed: false)
    private let empty = Label("", "dim").xalign(0.5).justify(GTK_JUSTIFY_CENTER).wrap()
    private let autoplay = Box.vertical(spacing: 8)
    private var showsEarlier = false
    private var shownListID: String?

    /// The next few hundred: a 28,000-track queue as a list is a lag spike every time it
    /// is drawn, and nobody scrolls that far.
    private static let limit = 300

    init(env: Env) {
        self.env = env
        let player = env.player

        let upNext = ToggleButton("Up Next")
        let earlier = ToggleButton("Earlier")
        earlier.group(with: upNext)
        upNext.isActive = true
        let tabs = Box.horizontal {
            earlier
            upNext
        }.css("linked")

        let options = MenuButton(icon: "view-more-symbolic", "flat", "circular") {
            Menu([[
                .action("Save Play Queue as Playlist…", enabled: !player.queue.tracks.isEmpty) {
                    let songs = player.queue.order.compactMap { player.queue.tracks.indices.contains($0) ? player.queue.tracks[$0] : nil }
                    Menus.newPlaylist(env, songs, suggested: player.queue.sourceDescription)
                },
                .action("Clear Play Queue", destructive: true, enabled: player.queue.hasUpNext) {
                    Dialogs.alert(
                        "Clear Play Queue?",
                        body: "The track playing keeps playing.",
                        responses: [("cancel", "Cancel", ADW_RESPONSE_DEFAULT), ("clear", "Clear Play Queue", ADW_RESPONSE_DESTRUCTIVE)]
                    ) { if $0 == "clear" { player.clearQueue() } }
                },
            ]])
        }

        let (list, empty, autoplay) = (self.list, self.empty, self.autoplay)
        let scroller = ScrolledWindow(Box.vertical(spacing: 12) {
            list
            empty
            autoplay
        }.margin(horizontal: 12, vertical: 0)).vexpand()

        root = Box.vertical(spacing: 8) {
            Box.horizontal(spacing: 12) {
                tabs
                Spacer()
                options
            }.margin(horizontal: 24, vertical: 0)
            scroller
        }
        root.keep(self)

        let reference = WeakReference(self)
        Signal.connect(earlier.widget, "toggled") {
            reference.value?.showsEarlier = earlier.isActive
            reference.value?.rebuild()
        }
        root.observe {
            _ = player.queue
            _ = player.currentSong?.id
            _ = env.app.guestDJ.dj
            reference.value?.rebuild()
        }
        root.observe {
            _ = env.app.autoplay.options
            _ = env.app.autoplay.selected
            _ = env.app.autoplay.isActive
            reference.value?.rebuildAutoplay()
        }
    }

    private func rebuild() {
        let player = env.player
        let queue = player.queue
        list.removeAll()

        let range: Range<Int>
        if showsEarlier {
            let end = min(queue.position, queue.order.count)
            range = max(0, end - Self.limit)..<max(0, end)
        } else {
            let start = queue.position + 1
            range = start < queue.order.count ? start..<min(queue.order.count, start + Self.limit) : 0..<0
        }

        if !showsEarlier, !queue.sourceDescription.isEmpty, !range.isEmpty {
            list.append(Label("Playing from \(queue.sourceDescription)", "caption", "dim").ellipsize().margin(horizontal: 12, vertical: 6))
        }
        let earlierMode = showsEarlier
        for orderIndex in range {
            let song = queue.tracks[queue.order[orderIndex]]
            let row = SongRowView(env, style: .artwork, showsNavigation: false)
            row.bind(song)
            let content = Box.horizontal(spacing: 6) { row.root.hexpand() }
            if env.app.guestDJ.isPick(song) {
                // Plexamp marks the DJ's picks, so its taste can be told from yours.
                content.append(Icon("starred-symbolic", size: 14).css("accent").tooltip("Picked by \(env.app.guestDJ.dj?.name ?? "the DJ")"))
            }
            if !showsEarlier {
                content.append(Button(icon: "list-remove-symbolic", "flat", "circular") {
                    player.removeFromQueue(orderIndex: orderIndex)
                }.tooltip("Remove from Queue").valign(GTK_ALIGN_CENTER))
            }
            content.contextMenu { [env] in
                var sections = Menus.song(env, song, showsNavigation: false).sections
                var queueItems: [Menu.Item] = [.action("Play Now") { player.jump(toOrderIndex: orderIndex) }]
                if !earlierMode {
                    if orderIndex > queue.position + 1 {
                        queueItems.append(.action("Move to Next") { player.moveInQueue(from: orderIndex, to: queue.position + 1) })
                        queueItems.append(.action("Move Up") { player.moveInQueue(from: orderIndex, to: orderIndex - 1) })
                    }
                    if orderIndex + 1 < queue.order.count {
                        queueItems.append(.action("Move Down") { player.moveInQueue(from: orderIndex, to: orderIndex + 2) })
                    }
                    queueItems.append(.action("Remove from Queue", destructive: true) { player.removeFromQueue(orderIndex: orderIndex) })
                }
                sections.insert(queueItems, at: 0)
                sections.append(Menus.navigationItems(env, song, jumps: true))
                return Menu(sections)
            }
            list.append(content) { player.jump(toOrderIndex: orderIndex) }
        }

        let autoplayShowing = env.app.autoplay.isActive && !env.app.autoplay.options.isEmpty
        if range.isEmpty {
            empty.text = showsEarlier ? "Earlier tracks in the play queue\nwill show up here" : "Nothing queued"
            empty.isVisible = showsEarlier || !autoplayShowing
        } else {
            empty.isVisible = false
        }
        autoplay.isVisible = !showsEarlier && autoplayShowing
    }

    /// Plexamp's Autoplay carousel: what plays when the queue runs out.
    private func rebuildAutoplay() {
        let service = env.app.autoplay
        autoplay.removeAll()
        guard service.isActive, !service.options.isEmpty else {
            autoplay.isVisible = false
            return
        }
        let title = Box.horizontal(spacing: 6) {
            Icon("media-playlist-repeat-symbolic", size: 14)
            Label("Autoplay", "heading")
        }
        if service.isAdding { title.append(Spinner().size(14)) }
        autoplay.append(title.margin(horizontal: 12, vertical: 0))

        let cards = Box.horizontal(spacing: 12)
        for option in service.options {
            let artwork = ArtworkView(env.app, size: .thumb, side: 96, shape: .card)
            artwork.show(option.coverArt, fallback: option.title)
            let card = Box.vertical(spacing: 4) {
                artwork.root
                Label(option.title, "caption-heading").ellipsize().maxWidthChars(1)
                Label(option.subtitle, "caption", "dim").ellipsize().maxWidthChars(1)
            }.size(width: 96)
            let button = Button(child: card, "card-button", "flat") { service.select(option.choice) }
            button.setCSS("suggested-action", service.selected == option.choice)
            cards.append(button)
        }
        autoplay.append(ScrolledWindow(cards, horizontal: GTK_POLICY_AUTOMATIC, vertical: GTK_POLICY_NEVER).propagatesNaturalHeight())
        autoplay.isVisible = !showsEarlier
    }
}
