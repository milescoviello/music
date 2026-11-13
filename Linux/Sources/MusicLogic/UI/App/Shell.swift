import CGtk
import Foundation

/// The window: a sidebar of sections where the phone has tabs, one history of pages through
/// all of them (`Navigation`), and the player as a layer over it all — the player bar along
/// the bottom, the
/// full player sliding up to fill the window, as Plexamp's does.
///
/// Narrow, the sidebar folds away and the window works like the phone: one page at a time,
/// back buttons, the bar at the bottom.
@MainActor
final class Shell {
    enum Section: String, CaseIterable {
        case home, library, search, downloads, settings

        /// The sidebar's sections, in its order; Settings sits apart at the bottom.
        static let listed: [Section] = [.home, .search, .library, .downloads]

        var title: String {
            switch self {
            case .home: return "Home"
            case .library: return "Library"
            case .search: return "Search"
            case .downloads: return "Downloads"
            case .settings: return "Settings"
            }
        }

        var icon: String {
            switch self {
            case .home: return "go-home-symbolic"
            case .library: return "folder-music-symbolic"
            case .search: return "system-search-symbolic"
            case .downloads: return "folder-download-symbolic"
            case .settings: return "emblem-system-symbolic"
            }
        }
    }

    let app: AppState
    let window: Widget
    /// Whether the window still exists: quitting after it has closed must not touch it.
    private let windowAlive: WeakObject
    private let toasts: ToastOverlay
    private let backdrop: WindowBackdrop
    private let root = Bin()
    private(set) var navigation: Navigation?
    private var split: NavigationSplitView?
    private var sheet: PlayerLayer?
    private var builtFor: AppState.Phase?
    var section: Section { navigation?.section ?? .home }

    init(application: OpaquePointer, app: AppState) {
        self.app = app
        let window = Widget(adw_application_window_new(application.cast())!)
        self.window = window
        windowAlive = window.liveness
        Desktop.window = window.widget
        gtk_window_set_title(window.widget.cast(), "Music")

        toasts = ToastOverlay(root)
        // Everything over the cover's colours, the toasts' overlay sizing the window.
        backdrop = WindowBackdrop(app: app)
        backdrop.root.add(toasts)
        gtk_overlay_set_measure_overlay(backdrop.root.widget.cast(), toasts.widget, 1)
        adw_application_window_set_content(window.widget.cast(), backdrop.root.widget)
        restoreSize()
        window.keep(self)

        let reference = WeakReference(self)
        window.observe {
            let phase = app.phase
            Task { @MainActor in reference.value?.show(phase) }
        }
        Signal.connect(window.widget, "notify::is-active", pointer: { _ in
            let active = gtk_window_is_active(window.widget.cast()) != 0
            reference.value?.backdrop.isActive = active
            guard active else { return }
            reference.value?.becameActive()
        })
        Signal.connectHandled(window.widget, "close-request") {
            guard let shell = reference.value else { return false }
            shell.saveSize()
            return shell.carryOnInBackground()
        }
        installKeys()
    }

    func present() {
        gtk_window_present(window.widget.cast())
        app.screenAwake.apply()
    }

    // MARK: - In the background

    /// The phone's background: closing the window while music plays or downloads run
    /// hides it and carries on, where it quit and stopped them. The launcher, a second
    /// launch or the media controls' Raise bring it back. Nothing to do for ten minutes
    /// with the window closed, it quits as closing it always did.
    private var backgroundCheck: guint = 0
    private var idleInBackground = 0
    private static let quitAfterIdleMinutes = 10

    /// True when the window was hidden instead of closed.
    private func carryOnInBackground() -> Bool {
        let playing = app.player.isPlaying
        let downloading = app.downloads.isDownloading
        guard playing || downloading else { return false }
        gtk_widget_set_visible(window.widget, 0)
        app.screenAwake.release()
        idleInBackground = 0
        let why = [playing ? "playing" : nil, downloading ? "downloading" : nil].compactMap { $0 }.joined(separator: " and ")
        Task { await Diagnostics.shared.record("app", "window closed while \(why): carrying on in the background") }
        guard backgroundCheck == 0 else { return true }
        let data = Unmanaged.passUnretained(self).toOpaque()
        backgroundCheck = g_timeout_add_seconds(60, { data in
            guard let data else { return 0 }
            let shell = Unmanaged<Shell>.fromOpaque(data).takeUnretainedValue()
            return MainActor.assumeIsolated { shell.checkBackground() } ? 1 : 0
        }, data)
        return true
    }

    /// Once a minute while the window is hidden. False stops the check.
    private func checkBackground() -> Bool {
        if gtk_widget_get_visible(window.widget) != 0 {
            backgroundCheck = 0
            return false
        }
        if app.player.isPlaying || app.downloads.isDownloading {
            idleInBackground = 0
            return true
        }
        idleInBackground += 1
        guard idleInBackground >= Self.quitAfterIdleMinutes else { return true }
        backgroundCheck = 0
        Task { await Diagnostics.shared.record("app", "quit after \(Self.quitAfterIdleMinutes) minutes in the background with nothing to do") }
        if let application = Desktop.application { g_application_quit(application.cast()) }
        return false
    }

    func toast(_ text: String) {
        toasts.show(text)
    }

    // MARK: - Phases

    private func show(_ phase: AppState.Phase) {
        guard builtFor != phase else { return }
        builtFor = phase
        switch phase {
        case .loading:
            root.child = Spinner().size(48).halign(GTK_ALIGN_CENTER).valign(GTK_ALIGN_CENTER)
        case .needsSetup:
            navigation = nil
            root.child = SetupPage.make(app)
        case .ready:
            root.child = makeMain()
        }
    }

    // MARK: - The main layout

    private func makeMain() -> Widget {
        let navigation = Navigation(app: app, shell: self)
        self.navigation = navigation
        NavigationPage.coverChanged = { [weak navigation] in navigation?.coverChanged() }
        for section in Section.allCases {
            navigation.addRoot(section, Pages.root(section, env: navigation.env))
        }

        let sidebarPage = makeSidebar()
        let contentPage = NavigationPage(navigation.view, title: "Music", tag: "content")
        let split = NavigationSplitView(sidebar: sidebarPage, content: contentPage)
            .sidebarWidth(min: 200, max: 280, fraction: 0.22)
        self.split = split
        addCollapseBreakpoint(split)
        Signal.connect(split.widget, "notify::collapsed", pointer: { [weak navigation] _ in
            navigation?.isCollapsed = split.isCollapsed
        })
        installHistoryButtons()

        let main = ToolbarView(content: split)
        main.top(RemoteQueueBar.make(app))
        main.top(offlineBanner())

        let player = NowPlaying(app: app, shell: self)
        let bar = PlayerBar(env: navigation.env, player: player)
        let sheet = PlayerLayer(content: main, player: player.root, bar: bar.root)
        self.sheet = sheet
        sheet.onOpenChanged { [app] open in
            if app.navigator.showsPlayer != open { app.navigator.showsPlayer = open }
        }

        let reference = WeakReference(self)
        sheet.root.observe { [app] in
            let hasQueue = app.player.hasQueue
            let shows = app.navigator.showsPlayer
            guard let shell = reference.value, let sheet = shell.sheet else { return }
            sheet.revealsBar = hasQueue
            sheet.canOpen = hasQueue
            sheet.isOpen = shows && hasQueue
        }
        // The backdrop's colours: the page's own cover where it has one (an album, an
        // artist), else the playing song's; the player always the playing song's.
        sheet.root.observe { [app] in
            let playing = app.player.currentSong?.coverArt
            let open = app.navigator.showsPlayer && app.player.hasQueue
            let page = navigation.current?.page
            _ = navigation.coverChanges
            guard let shell = reference.value else { return }
            shell.backdrop.show(cover: open ? playing : page?.coverArt ?? playing)
        }
        // Jumps out of the player, and from anywhere else that asks.
        sheet.root.observe { [app] in
            guard !app.navigator.requests.isEmpty else { return }
            Task { @MainActor in reference.value?.takeNavigationRequests() }
        }
        // Menus give no feedback of their own, so playlist changes say so.
        sheet.root.observe { [app] in
            guard let message = app.playlistStore.lastMessage else { return }
            Task { @MainActor in
                reference.value?.toast(message)
                app.playlistStore.lastMessage = nil
            }
        }
        select(.home)
        return sheet.root
    }

    private func makeSidebar() -> NavigationPage {
        let list = ListBox(boxed: false)
        gtk_list_box_set_selection_mode(list.widget.cast(), GTK_SELECTION_SINGLE)
        list.css("navigation-sidebar")
        for section in Section.listed {
            list.append(sidebarRow(section)) { [weak self] in self?.select(section) }
        }

        let settings = ListBox(boxed: false)
        gtk_list_box_set_selection_mode(settings.widget.cast(), GTK_SELECTION_SINGLE)
        settings.css("navigation-sidebar")
        settings.append(sidebarRow(.settings)) { [weak self] in self?.select(.settings) }

        let body = Box.vertical(spacing: 0) {
            list
            pinnedList()
        }
        let header = HeaderBar().title(WindowTitle("Music"))
        header.end(MenuButton(icon: "open-menu-symbolic", "flat") { [app] in
            Menu([
                [.action("Settings") { [weak self] in self?.select(.settings) }],
                [.action("Sign Out", destructive: true) { Task { await app.signOut() } }],
                [.action("Quit") { if let application = Desktop.application { g_application_quit(application.cast()) } }],
            ])
        })
        let page = ToolbarView(content: Box.vertical(spacing: 0) {
            ScrolledWindow(body).vexpand()
            settings.margins(top: 0, bottom: 6, start: 0, end: 0)
        }).top(header)
        page.css("sidebar-pane")

        // The row of the section showing, whichever way it was reached.
        page.observe { [weak self] in
            guard let self, let navigation else { return }
            let section = navigation.section
            gtk_list_box_unselect_all(list.widget.cast())
            gtk_list_box_unselect_all(settings.widget.cast())
            if let index = Section.listed.firstIndex(of: section),
               let row = gtk_list_box_get_row_at_index(list.widget.cast(), Int32(index)) {
                gtk_list_box_select_row(list.widget.cast(), row)
            } else if section == .settings, let row = gtk_list_box_get_row_at_index(settings.widget.cast(), 0) {
                gtk_list_box_select_row(settings.widget.cast(), row)
            }
        }
        return NavigationPage(page, title: "Music", tag: "sidebar")
    }

    private func sidebarRow(_ section: Section) -> Widget {
        let row = Box.horizontal(spacing: 12) {
            Icon(section.icon)
            Label(section.title).hexpand().xalign(0)
        }.margin(horizontal: 6, vertical: 6)
        if section == .downloads {
            let badge = Label("", "badge").valign(GTK_ALIGN_CENTER)
            row.append(badge)
            badge.observe { [app] in
                let count = app.downloads.activeCount
                badge.text = String(count)
                badge.isVisible = count > 0
            }
        }
        return row
    }

    /// The playlists pinned in Library, under the sections: the phone's "my main 4".
    private func pinnedList() -> Widget {
        let heading = Label("Pinned", "sidebar-heading").xalign(0).margins(top: 18, bottom: 4, start: 18, end: 12)
        let list = ListBox(boxed: false)
        list.css("navigation-sidebar", "pinned-list")
        let box = Box.vertical(spacing: 0) {
            heading
            list
        }
        box.observe { [app, weak self] in
            let pinned = app.playlistArrangement.pinned
            let playlists = app.playlistStore.playlists
            let shown = pinned.compactMap { id in playlists.first { $0.id == id } }
            list.removeAll()
            box.isVisible = !shown.isEmpty
            for playlist in shown {
                let artwork = ArtworkView(app, size: .thumb, side: 32, shape: .thumb)
                artwork.show(playlist.coverArt, playlistID: playlist.id, fallback: playlist.name)
                let row = Box.horizontal(spacing: 10) {
                    artwork.root
                    Label(playlist.name).hexpand().xalign(0).ellipsize()
                }.margin(horizontal: 6, vertical: 2)
                let ref = PlaylistRef(id: playlist.id, name: playlist.name, coverArt: playlist.coverArt)
                list.append(row) { self?.navigation?.push(.playlist(ref)) }
            }
        }
        return box
    }

    /// Selects a section from the sidebar, a menu or a key: its first page, as a step in
    /// the history; on it already, the top of it.
    func select(_ section: Section) {
        navigation?.open(section)
        split?.showsContent = true
    }

    func showContent() {
        split?.showsContent = true
    }

    func showSidebar() {
        split?.showsContent = false
    }

    private func takeNavigationRequests() {
        let requests = app.navigator.takeRequests()
        guard !requests.isEmpty, let navigation else { return }
        if app.navigator.wantsLibraryTab { app.navigator.didSelectLibraryTab() }
        for destination in requests { navigation.push(destination) }
    }

    /// The mouse's back and forward buttons, anywhere in the window.
    private func installHistoryButtons() {
        let gesture = gtk_gesture_click_new()!
        gtk_gesture_single_set_button(gesture.cast(), 0)
        gtk_event_controller_set_propagation_phase(gesture.cast(), GTK_PHASE_CAPTURE)
        let reference = WeakReference(self)
        Signal.connect(gesture, "pressed", press: { _, _, _ in
            guard let shell = reference.value, shell.sheet?.isOpen != true else { return }
            switch gtk_gesture_single_get_current_button(gesture.cast()) {
            case 8: shell.navigation?.goBack()
            case 9: shell.navigation?.goForward()
            default: return
            }
        })
        gtk_widget_add_controller(window.widget, gesture.cast())
    }

    /// Below 640 points wide, one page at a time, as on the phone.
    private func addCollapseBreakpoint(_ split: NavigationSplitView) {
        guard let condition = adw_breakpoint_condition_parse("max-width: 640sp"),
              let breakpoint = adw_breakpoint_new(condition)
        else { return }
        var value = GValue()
        g_value_init(&value, GType(5 << 2))
        g_value_set_boolean(&value, 1)
        adw_breakpoint_add_setter(breakpoint, split.widget.gobject, "collapsed", &value)
        g_value_unset(&value)
        adw_application_window_add_breakpoint(window.widget.cast(), breakpoint)
    }

    /// Says the app is offline, once, at the top, with the way to what still plays.
    private func offlineBanner() -> Widget {
        let banner = Banner("", button: "Downloads") { [weak self] in self?.select(.downloads) }
        banner.observe { [app] in
            let offline = !app.reachability.isOnline || app.isShowingCachedData
            let count = app.downloads.catalog.entries.count
            // A network, and a server that did not answer, is not "offline".
            banner.title = app.reachability.isOnline
                ? "The server isn’t answering — showing saved copies"
                : count > 0
                    ? "Offline — \(count) downloaded \(count == 1 ? "track" : "tracks") available"
                    : "Offline — nothing is downloaded yet"
            banner.isRevealed = offline
        }
        return banner
    }

    // MARK: - Lifecycle

    /// The phone's return to the foreground: the most likely moment to have a network
    /// again, and for another device to have moved the queue on.
    private func becameActive() {
        guard app.phase == .ready else { return }
        app.player.appBecameActive()
        Task { await app.flushOutbox() }
        Task { await app.refreshRequests() }
        Task { await app.sonic.refreshStatus() }
        Task { await app.playlistSync.sync() }
        app.downloads.resumeWaiting()
        Task { await app.mostPlayed.refresh() }
        Task { await app.playlistStore.refreshIfStale() }
        Task { await app.queueSync.check(localSavedAt: app.player.lastSavedAt) }
    }

    private func restoreSize() {
        let defaults = UserDefaults.standard
        let width = defaults.integer(forKey: "window.width")
        let height = defaults.integer(forKey: "window.height")
        gtk_window_set_default_size(window.widget.cast(), Int32(width > 0 ? width : 1180), Int32(height > 0 ? height : 820))
        if defaults.bool(forKey: "window.maximized") { gtk_window_maximize(window.widget.cast()) }
        // Small enough for Plexamp's smallest player; the library asks for more itself
        // when it is showing.
        gtk_widget_set_size_request(window.widget, 200, 150)
    }

    /// Also called on quit: Ctrl+Q and SIGTERM end the application without a close-request.
    func saveSize() {
        guard windowAlive.isAlive else { return }
        var width: Int32 = 0
        var height: Int32 = 0
        gtk_window_get_default_size(window.widget.cast(), &width, &height)
        let defaults = UserDefaults.standard
        defaults.set(Int(width), forKey: "window.width")
        defaults.set(Int(height), forKey: "window.height")
        defaults.set(gtk_window_is_maximized(window.widget.cast()) != 0, forKey: "window.maximized")
    }

    // MARK: - Keys

    /// Space plays and pauses, as in every desktop player — unless typing. Ctrl+F searches;
    /// Ctrl+Left and Right skip; Alt+Left and Right go back and forward; Escape closes the
    /// player.
    private func installKeys() {
        let controller = gtk_event_controller_key_new()!
        gtk_event_controller_set_propagation_phase(controller, GTK_PHASE_CAPTURE)
        let reference = WeakReference(self)
        Signal.connect(controller, "key-pressed", key: { keyval, _, state in
            guard let shell = reference.value, shell.app.phase == .ready else { return false }
            let control = state.rawValue & GDK_CONTROL_MASK.rawValue != 0
            let alt = state.rawValue & GDK_ALT_MASK.rawValue != 0
            let typing = shell.isTyping
            switch Int32(keyval) {
            case GDK_KEY_space where !typing && !control:
                shell.app.player.togglePlayPause()
                return true
            case GDK_KEY_f where control:
                shell.sheet?.isOpen = false
                shell.select(.search)
                SearchPage.focus(shell.navigation)
                return true
            case GDK_KEY_Left where alt && shell.sheet?.isOpen != true:
                shell.navigation?.goBack()
                return true
            case GDK_KEY_Right where alt && shell.sheet?.isOpen != true:
                shell.navigation?.goForward()
                return true
            case GDK_KEY_Back:
                shell.navigation?.goBack()
                return true
            case GDK_KEY_Forward:
                shell.navigation?.goForward()
                return true
            case GDK_KEY_Right where control:
                shell.app.player.next()
                return true
            case GDK_KEY_Left where control:
                shell.app.player.previous()
                return true
            case GDK_KEY_Escape where shell.sheet?.isOpen == true:
                shell.app.navigator.showsPlayer = false
                return true
            default:
                return false
            }
        })
        gtk_widget_add_controller(window.widget, controller)
    }

    private var isTyping: Bool {
        guard let focus = gtk_window_get_focus(window.widget.cast()) else { return false }
        return g_type_check_instance_is_a(UnsafeMutableRawPointer(focus).assumingMemoryBound(to: GTypeInstance.self), gtk_editable_get_type()) != 0
            || g_type_check_instance_is_a(UnsafeMutableRawPointer(focus).assumingMemoryBound(to: GTypeInstance.self), gtk_text_get_type()) != 0
    }
}

/// Offered rather than applied: another device's queue arriving unannounced and replacing
/// what was playing would be worse than not syncing at all.
@MainActor
enum RemoteQueueBar {
    static func make(_ app: AppState) -> Widget {
        let title = Label("", "heading")
        let detail = Label("", "caption", "dim").ellipsize()
        let bar = Box.horizontal(spacing: 12) {
            Icon("view-refresh-symbolic").css("accent")
            Box.vertical(spacing: 0) {
                title
                detail
            }.hexpand()
            Button("Resume", "suggested-action", "pill") { app.adoptRemoteQueue() }
            Button(icon: "window-close-symbolic", "flat", "circular") { app.queueSync.dismiss() }
                .tooltip("Dismiss")
        }.margin(horizontal: 16, vertical: 8)
        let revealer = Revealer(bar)
        revealer.observe {
            guard let remote = app.queueSync.available else {
                revealer.isRevealed = false
                return
            }
            title.text = "Continue from \(remote.changedBy)?"
            if let first = remote.songs.first {
                detail.text = remote.songs.count == 1 ? first.title : "\(first.title) + \(remote.songs.count - 1) more"
            }
            revealer.isRevealed = true
        }
        return revealer
    }
}
