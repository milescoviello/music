import CGtk
import Foundation

/// The play queue, the phone's `QueueView`: Earlier, Up Next and Related in a segmented
/// picker, Edit and the queue's menu beside it, the songs as plain rows (a right-click is
/// the phone's long press; dragging moves one, as Edit's handles do there).
/// Autoplay's choices sit at the end of Up Next, shown as what they are, with the songs
/// the selected one will play listed under them.
@MainActor
final class QueuePane {
    enum Tab: Int, CaseIterable {
        // Remembered by number, so Lyrics, which came later, comes last here.
        case backTo, upNext, related, lyrics

        /// In the order the phone's picker shows them. The lyrics are the player's own
        /// mode there, not a tab of the queue.
        static let shown: [Tab] = [.backTo, .upNext, .related]

        var title: String {
            switch self {
            case .lyrics: return "Lyrics"
            case .backTo: return "Earlier"
            case .upNext: return "Up Next"
            case .related: return "Related"
            }
        }
    }

    let root: Box
    private let env: Env
    private let pages = Stack(transition: GTK_STACK_TRANSITION_TYPE_NONE)
    private var tabButtons: [Tab: ToggleButton] = [:]
    private var tab: Tab
    private let backList = PlainList.list()
    private let upNextList = PlainList.list()
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
        if UserDefaults.standard.object(forKey: Self.tabKey) == nil || tab == .lyrics { tab = .upNext }

        let picker = Box.horizontal(spacing: 0).homogeneous().css("segmented")
        var first: ToggleButton?
        for candidate in Tab.shown {
            let button = ToggleButton(candidate.title, "segment")
            if let first { button.group(with: first) }
            first = first ?? button
            tabButtons[candidate] = button
            picker.append(button)
        }
        // The queue's own menu: a queue built by hand is the one thing that exists nowhere
        // else, so it gets a way out to a playlist.
        let player = env.player
        let menu = MenuButton(icon: Symbol.icon("ellipsis.circle"), "flat", "np-top-button") { [env] in
            Menu([[
                .action("Save Play Queue as Playlist…", enabled: !player.queue.tracks.isEmpty) {
                    let songs = player.queue.order.compactMap { player.queue.tracks.indices.contains($0) ? player.queue.tracks[$0] : nil }
                    Menus.newPlaylist(env, songs, suggested: player.queue.sourceDescription)
                },
                .action("Clear Play Queue", destructive: true, enabled: player.queue.hasUpNext || player.queue.position > 0) {
                    Dialogs.alert(
                        "Clear Play Queue?",
                        body: "The track playing keeps playing.",
                        responses: [("cancel", "Cancel", ADW_RESPONSE_DEFAULT), ("clear", "Clear Play Queue", ADW_RESPONSE_DESTRUCTIVE)]
                    ) { if $0 == "clear" { player.clearQueue() } }
                },
            ]])
        }
        menu.tooltip("Queue Options")
        let bar = Box.horizontal(spacing: 12) {
            picker.size(width: 300, height: -1)
            Spacer()
            menu
        }.margin(horizontal: 24, vertical: 4)

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
        // The lyrics beside the cover, rather than in its place.
        pages.add(LyricsPane(env: env).root, name: "\(Tab.lyrics.rawValue)")
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
            _ = env.app.autoplay.isAdding
            _ = env.app.autoplay.upcoming
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

    /// Chooses a tab from outside: the player's Lyrics button, with the queue beside it.
    func select(_ target: Tab) {
        tabButtons[target]?.isActive = true
        show(target)
    }

    var showsLyrics: Bool { tab == .lyrics }
    /// The player's, to light its Lyrics button while the tab shows.
    var onTabChanged: (@MainActor () -> Void)?

    private func show(_ target: Tab) {
        defer { onTabChanged?() }
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
        let artwork = ArtworkView(env.app, size: .thumb, side: 40, shape: .thumb)
        artwork.show(song.coverArt, fallback: song.album ?? song.title)
        // The stars follow the rating from the row's own observer. Read while the queue
        // was built, every rating anywhere rebuilt the whole queue.
        let stars = Label("", "queue-stars")
        let user = env.app.userState
        stars.observe {
            let rating = min(max(user.rating(song), 0), 5)
            stars.text = String(repeating: "★", count: rating) + String(repeating: "☆", count: 5 - rating)
            stars.isVisible = rating > 0
        }
        let subtitle = Box.horizontal(spacing: 6) {
            Label([song.artist, song.album].compactMap { $0 }.joined(separator: " — "), "plain-subtitle").ellipsize().xalign(0)
            stars
        }
        let env = env
        let body = Box.horizontal(spacing: 8) {
            Box.vertical(spacing: 2) {
                Label(song.title, "plain-title").ellipsize().xalign(0)
                subtitle
            }.hexpand().valign(GTK_ALIGN_CENTER)
        }.css("plain-row-body")
        body.size(width: -1, height: 62)
        if marked {
            // Plexamp marks the Guest DJ's picks, so its taste can be told from yours.
            body.append(Icon(Symbol.icon("sparkles"), size: 13).css("accent").tooltip("Picked by \(env.app.guestDJ.dj?.name ?? "the DJ")").valign(GTK_ALIGN_CENTER))
        }
        let line = Box.horizontal(spacing: 12) {
            artwork.root.valign(GTK_ALIGN_CENTER)
            body.hexpand()
        }
        line.css("queue-row", "plain-row")
        line.contextMenu { [env] in
            var sections = Menus.song(env, song, showsNavigation: false, showsQueueItems: false).sections
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
            let actions: [Menu.Item] = [
                .action("Play Now") { player.jump(toOrderIndex: orderIndex) },
                // Moved, not copied: the song goes from here to straight after this one.
                .action("Play Next") { player.moveInQueue(from: orderIndex, to: queue.position + 1) },
                .action("Remove from Queue", destructive: true) { player.removeFromQueue(orderIndex: orderIndex) },
            ]
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
                actions.append(.action("Move to End") { player.moveToEnd(fromOrderIndex: orderIndex) })
            }
            actions.append(.action("Remove from Queue", destructive: true) { player.removeFromQueue(orderIndex: orderIndex) })
            // Dragged onto another row, a song takes that row's place, as on the phone.
            let line = row(song, actions: actions, marked: env.app.guestDJ.isPick(song))
                .draggable("\(orderIndex)")
                .onDrop { text in
                    guard let from = Int(text), from != orderIndex, from > queue.position else { return false }
                    player.moveInQueue(from: from, to: from < orderIndex ? orderIndex + 1 : orderIndex)
                    return true
                }
            upNextList.append(line) { player.jump(toOrderIndex: orderIndex) }
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

        // What the selected card will play when the queue runs out, so the end of the
        // queue says what is coming. Clicking one adds them now and plays from it.
        if let from = service.upcomingOption, !service.upcoming.isEmpty {
            autoplay.append(Label("Then, from \(from.title):", "caption", "dim").xalign(0).ellipsize().margin(horizontal: 6, vertical: 0))
            let list = ListBox(boxed: false)
            for (index, song) in service.upcoming.enumerated() {
                let actions: [Menu.Item] = [.action("Play from Here") { service.play(fromUpcoming: index) }]
                list.append(row(song, actions: actions, marked: false)) { service.play(fromUpcoming: index) }
            }
            autoplay.append(list)
        }
        autoplay.isVisible = true
    }
}
