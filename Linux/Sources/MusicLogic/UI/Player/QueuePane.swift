import CGtk
import Foundation

/// The play queue, Plexamp's way: three tabs, BACK TO what already played, UP NEXT, and
/// RELATED tracks to the one playing — Plexamp's queue under or beside its player.
/// Autoplay's choices sit at the end of Up Next, shown as what they are.
@MainActor
final class QueuePane {
    enum Tab: Int, CaseIterable {
        case backTo, upNext, related

        var title: String {
            switch self {
            case .backTo: return "BACK TO"
            case .upNext: return "UP NEXT"
            case .related: return "RELATED"
            }
        }
    }

    let root: Box
    private let env: Env
    private let pages = Stack(transition: GTK_STACK_TRANSITION_TYPE_SLIDE_LEFT_RIGHT)
    private var tabButtons: [Tab: ToggleButton] = [:]
    private var tab: Tab
    private let backList = ListBox(boxed: false)
    private let upNextList = ListBox(boxed: false)
    private let relatedBox = Box.vertical(spacing: 6)
    private let empty = Label("", "dim").xalign(0.5).justify(GTK_JUSTIFY_CENTER).wrap()
    private let backEmpty = Label("Earlier tracks in the play queue\nwill show up here", "dim").xalign(0.5).justify(GTK_JUSTIFY_CENTER).wrap()
    private let autoplay = Box.vertical(spacing: 8)
    private var relatedFor: String?
    private var relatedGeneration = 0

    /// Where the tab is remembered: Plexamp's `playQueueTabIndex`.
    private static let tabKey = "player.queueTab"
    /// The next few hundred: a 28,000-track queue as a list is a lag spike every time it
    /// is drawn, and nobody scrolls that far.
    private static let limit = 300

    init(env: Env) {
        self.env = env
        tab = Tab(rawValue: UserDefaults.standard.integer(forKey: Self.tabKey)) ?? .upNext
        if UserDefaults.standard.object(forKey: Self.tabKey) == nil { tab = .upNext }

        let bar = Box.horizontal(spacing: 0).homogeneous().css("queue-tabs")
        var first: ToggleButton?
        for candidate in Tab.allCases {
            let button = ToggleButton(candidate.title, "flat", "queue-tab")
            if let first { button.group(with: first) }
            first = first ?? button
            tabButtons[candidate] = button
            bar.append(button)
        }

        let (backList, upNextList, empty, backEmpty, autoplay, relatedBox) =
            (self.backList, self.upNextList, self.empty, self.backEmpty, self.autoplay, self.relatedBox)
        pages.add(Self.scroller(Box.vertical(spacing: 8) {
            backList
            backEmpty
        }), name: "\(Tab.backTo.rawValue)")
        pages.add(Self.scroller(Box.vertical(spacing: 12) {
            upNextList
            empty
            autoplay
        }), name: "\(Tab.upNext.rawValue)")
        pages.add(Self.scroller(relatedBox), name: "\(Tab.related.rawValue)")
        pages.vexpand()

        let pages = self.pages
        root = Box.vertical(spacing: 4) {
            bar
            pages
        }
        root.css("queue-pane")
        root.keep(self)

        let reference = WeakReference(self)
        for (candidate, button) in tabButtons {
            Signal.connect(button.widget, "toggled") {
                guard button.isActive, let pane = reference.value else { return }
                pane.show(candidate)
            }
        }
        tabButtons[tab]?.isActive = true
        show(tab)

        let player = env.player
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
        root.observe {
            _ = player.currentSong?.id
            guard let pane = reference.value, pane.tab == .related else { return }
            pane.loadRelated()
        }
    }

    private static func scroller(_ content: Widget) -> Widget {
        ScrolledWindow(content.margin(horizontal: 6, vertical: 0)).vexpand()
    }

    private func show(_ target: Tab) {
        tab = target
        UserDefaults.standard.set(target.rawValue, forKey: Self.tabKey)
        pages.visibleName = "\(target.rawValue)"
        for (candidate, button) in tabButtons { button.setCSS("selected", candidate == target) }
        if target == .related { loadRelated() }
    }

    // MARK: - Rows

    /// Plexamp's queue row: the cover, the title, the artist with the track's stars, and
    /// a menu at the end.
    private func row(_ song: Song, actions: [Menu.Item], marked: Bool) -> Widget {
        let artwork = ArtworkView(env.app, size: .thumb, side: 37, shape: .thumb)
        artwork.show(song.coverArt, fallback: song.album ?? song.title)
        let subtitle = Box.horizontal(spacing: 6) {
            Label(song.artist ?? "", "queue-artist").ellipsize()
        }
        let rating = min(max(env.app.userState.rating(song), 0), 5)
        if rating > 0 {
            subtitle.append(Label(String(repeating: "★", count: rating) + String(repeating: "☆", count: 5 - rating), "queue-stars"))
        }
        let env = env
        let menu = MenuButton(icon: "view-more-symbolic", "flat", "circular", "queue-more") {
            var sections = Menus.song(env, song, showsNavigation: false).sections
            if !actions.isEmpty { sections.insert(actions, at: 0) }
            sections.append(Menus.navigationItems(env, song, jumps: true))
            return Menu(sections)
        }
        menu.valign(GTK_ALIGN_CENTER)
        let line = Box.horizontal(spacing: 10) {
            artwork.root
            Box.vertical(spacing: 1) {
                Label(song.title, "queue-title").ellipsize().xalign(0)
                subtitle
            }.hexpand().valign(GTK_ALIGN_CENTER)
        }
        if marked {
            // Plexamp marks the Guest DJ's picks, so its taste can be told from yours.
            line.append(Icon("starred-symbolic", size: 12).css("accent").tooltip("Picked by \(env.app.guestDJ.dj?.name ?? "the DJ")").valign(GTK_ALIGN_CENTER))
        }
        line.append(menu)
        line.css("queue-row")
        line.contextMenu { [env] in
            var sections = Menus.song(env, song, showsNavigation: false).sections
            if !actions.isEmpty { sections.insert(actions, at: 0) }
            sections.append(Menus.navigationItems(env, song, jumps: true))
            return Menu(sections)
        }
        return line
    }

    private func rebuild() {
        let player = env.player
        let queue = player.queue

        // Back To: the most recent first, as Plexamp lists them.
        backList.removeAll()
        let end = min(queue.position, queue.order.count)
        let earlier = max(0, end - Self.limit)..<max(0, end)
        for orderIndex in earlier.reversed() {
            let song = queue.tracks[queue.order[orderIndex]]
            let actions: [Menu.Item] = [.action("Play Now") { player.jump(toOrderIndex: orderIndex) }]
            backList.append(row(song, actions: actions, marked: false)) { player.jump(toOrderIndex: orderIndex) }
        }
        backEmpty.isVisible = earlier.isEmpty

        upNextList.removeAll()
        let start = queue.position + 1
        let upcoming = start < queue.order.count ? start..<min(queue.order.count, start + Self.limit) : 0..<0
        for orderIndex in upcoming {
            let song = queue.tracks[queue.order[orderIndex]]
            var actions: [Menu.Item] = [.action("Play Now") { player.jump(toOrderIndex: orderIndex) }]
            if orderIndex > queue.position + 1 {
                actions.append(.action("Move to Next") { player.moveInQueue(from: orderIndex, to: queue.position + 1) })
                actions.append(.action("Move Up") { player.moveInQueue(from: orderIndex, to: orderIndex - 1) })
            }
            if orderIndex + 1 < queue.order.count {
                actions.append(.action("Move Down") { player.moveInQueue(from: orderIndex, to: orderIndex + 2) })
            }
            actions.append(.action("Remove from Queue", destructive: true) { player.removeFromQueue(orderIndex: orderIndex) })
            upNextList.append(row(song, actions: actions, marked: env.app.guestDJ.isPick(song))) { player.jump(toOrderIndex: orderIndex) }
        }
        let autoplayShowing = env.app.autoplay.isActive && !env.app.autoplay.options.isEmpty
        empty.text = "Nothing queued"
        empty.isVisible = upcoming.isEmpty && !autoplayShowing
        autoplay.isVisible = autoplayShowing
    }

    /// Plexamp's Related tab: the track's sonically similar, related and comfort-zone
    /// lists, fetched when the tab is first looked at for each track.
    private func loadRelated() {
        guard let song = env.player.currentSong, relatedFor != song.id else { return }
        relatedFor = song.id
        relatedGeneration += 1
        let generation = relatedGeneration
        relatedBox.removeAll()
        relatedBox.append(Spinner().size(24).halign(GTK_ALIGN_CENTER).margin(24))
        let reference = WeakReference(self)
        let env = env
        Task { @MainActor in
            let lists = await SimilarTracks.lists(env, song: song, limit: 20)
            guard let pane = reference.value, pane.relatedGeneration == generation else { return }
            pane.relatedBox.removeAll()
            guard !lists.isEmpty else {
                pane.relatedBox.append(Label("There isn't another like it.", "dim").xalign(0.5).margin(24))
                return
            }
            for (kind, songs) in lists {
                let source = "\(kind.rawValue) · \(song.title)"
                pane.relatedBox.append(Label(kind.heading.uppercased(), "queue-heading").xalign(0).margin(horizontal: 6, vertical: 6))
                let list = ListBox(boxed: false)
                for (index, related) in songs.enumerated() {
                    let actions: [Menu.Item] = [
                        .action("Play Now") { env.play(songs, from: index, source: source) },
                        .action("Play Next") { env.player.playNext([related]) },
                    ]
                    list.append(pane.row(related, actions: actions, marked: false)) { env.play(songs, from: index, source: source) }
                }
                pane.relatedBox.append(list)
            }
        }
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
        autoplay.append(title.margin(horizontal: 6, vertical: 0))

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
        autoplay.isVisible = true
    }
}
