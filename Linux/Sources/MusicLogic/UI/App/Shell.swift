import CGtk
import Foundation

/// The window: a sidebar of sections where the phone has tabs, each section its own stack
/// of pages, and the player as a bottom sheet — the mini player along the bottom, the full
/// player sliding up over everything, as the phone's player is a layer over the library.
///
/// Narrow, the sidebar folds away and the window works like the phone: one page at a time,
/// back buttons, the bar at the bottom.
@MainActor
final class Shell {
    enum Section: String, CaseIterable {
        case home, library, search, downloads, settings

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
    private let toasts: ToastOverlay
    private let root = Bin()
    private var navigations: [Section: Navigation] = [:]
    private var content = Stack(transition: GTK_STACK_TRANSITION_TYPE_NONE)
    private var sidebar: ListBox?
    private var split: NavigationSplitView?
    private var sheet: BottomSheet?
    private var builtFor: AppState.Phase?
    private(set) var section: Section = .home

    init(application: OpaquePointer, app: AppState) {
        self.app = app
        let window = Widget(adw_application_window_new(application.cast())!)
        self.window = window
        Desktop.window = window.widget
        gtk_window_set_title(window.widget.cast(), "Music")

        toasts = ToastOverlay(root)
        adw_application_window_set_content(window.widget.cast(), toasts.widget)
        restoreSize()
        window.keep(self)

        let reference = WeakReference(self)
        window.observe {
            let phase = app.phase
            Task { @MainActor in reference.value?.show(phase) }
        }
        Signal.connect(window.widget, "notify::is-active", pointer: { _ in
            guard gtk_window_is_active(window.widget.cast()) != 0 else { return }
            reference.value?.becameActive()
        })
        Signal.connectHandled(window.widget, "close-request") {
            reference.value?.saveSize()
            return false
        }
        installKeys()
    }

    func present() {
        gtk_window_present(window.widget.cast())
        app.screenAwake.apply()
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
            navigations = [:]
            root.child = SetupPage.make(app)
        case .ready:
            root.child = makeMain()
        }
    }

    // MARK: - The main layout

    private func makeMain() -> Widget {
        content = Stack(transition: GTK_STACK_TRANSITION_TYPE_CROSSFADE)
        navigations = [:]
        for section in Section.allCases {
            let navigation = Navigation(app: app, shell: self)
            navigation.setRoot(Pages.root(section, env: navigation.env))
            navigations[section] = navigation
            content.add(navigation.view, name: section.rawValue)
        }

        let sidebarPage = makeSidebar()
        let contentPage = NavigationPage(content, title: "Music", tag: "content")
        let split = NavigationSplitView(sidebar: sidebarPage, content: contentPage)
            .sidebarWidth(min: 180, max: 260, fraction: 0.22)
        self.split = split
        addCollapseBreakpoint(split)

        let main = ToolbarView(content: split)
        main.top(RemoteQueueBar.make(app))
        main.top(offlineBanner())

        let player = NowPlaying(app: app, shell: self)
        let mini = MiniPlayer(app: app)
        let sheet = BottomSheet(content: main, sheet: player.root, bar: mini.root)
        self.sheet = sheet
        sheet.onOpenChanged { [app] open in
            if app.navigator.showsPlayer != open { app.navigator.showsPlayer = open }
        }

        let reference = WeakReference(self)
        sheet.observe { [app] in
            let hasQueue = app.player.hasQueue
            let shows = app.navigator.showsPlayer
            guard let shell = reference.value, let sheet = shell.sheet else { return }
            sheet.revealsBar = hasQueue
            sheet.canOpen = hasQueue
            sheet.isOpen = shows && hasQueue
        }
        // Jumps out of the player, and from anywhere else that asks.
        sheet.observe { [app] in
            guard !app.navigator.requests.isEmpty else { return }
            Task { @MainActor in reference.value?.takeNavigationRequests() }
        }
        // Menus give no feedback of their own, so playlist changes say so.
        sheet.observe { [app] in
            guard let message = app.playlistStore.lastMessage else { return }
            Task { @MainActor in
                reference.value?.toast(message)
                app.playlistStore.lastMessage = nil
            }
        }
        select(.home)
        return sheet
    }

    private func makeSidebar() -> NavigationPage {
        let list = ListBox(boxed: false)
        gtk_list_box_set_selection_mode(list.widget.cast(), GTK_SELECTION_BROWSE)
        list.css("navigation-sidebar")
        for section in Section.allCases {
            let label = Label(section.title).hexpand()
            let row = Box.horizontal(spacing: 12) {
                Icon(section.icon)
                label
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
            list.append(row) { [weak self] in self?.select(section) }
        }
        sidebar = list

        let header = HeaderBar().title(WindowTitle("Music"))
        header.end(MenuButton(icon: "open-menu-symbolic", "flat") { [app] in
            Menu([
                [.action("Settings") { [weak self] in self?.select(.settings) }],
                [.action("Sign Out", destructive: true) { Task { await app.signOut() } }],
                [.action("Quit") { if let application = Desktop.application { g_application_quit(application.cast()) } }],
            ])
        })
        let page = ToolbarView(content: ScrolledWindow(list).vexpand()).top(header)
        return NavigationPage(page, title: "Music", tag: "sidebar")
    }

    /// Selects a section, showing its page stack where it was left.
    func select(_ section: Section) {
        self.section = section
        content.visibleName = section.rawValue
        if let sidebar, let index = Section.allCases.firstIndex(of: section),
           let row = gtk_list_box_get_row_at_index(sidebar.widget.cast(), Int32(index)) {
            gtk_list_box_select_row(sidebar.widget.cast(), row)
        }
        split?.showsContent = true
    }

    func navigation(_ section: Section) -> Navigation? {
        navigations[section]
    }

    private func takeNavigationRequests() {
        let requests = app.navigator.takeRequests()
        guard !requests.isEmpty, let library = navigations[.library] else { return }
        if app.navigator.wantsLibraryTab {
            select(.library)
            app.navigator.didSelectLibraryTab()
        }
        for destination in requests { library.push(destination) }
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
            banner.title = count > 0
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
        Task { await app.queueSync.check(localSavedAt: app.player.lastSavedAt) }
    }

    private func restoreSize() {
        let defaults = UserDefaults.standard
        let width = defaults.integer(forKey: "window.width")
        let height = defaults.integer(forKey: "window.height")
        gtk_window_set_default_size(window.widget.cast(), Int32(width > 0 ? width : 1180), Int32(height > 0 ? height : 820))
        if defaults.bool(forKey: "window.maximized") { gtk_window_maximize(window.widget.cast()) }
        gtk_widget_set_size_request(window.widget, 360, 480)
    }

    /// Also called on quit: Ctrl+Q and SIGTERM end the application without a close-request.
    func saveSize() {
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
    /// Ctrl+Left and Right skip; Escape closes the player.
    private func installKeys() {
        let controller = gtk_event_controller_key_new()!
        gtk_event_controller_set_propagation_phase(controller, GTK_PHASE_CAPTURE)
        let reference = WeakReference(self)
        Signal.connect(controller, "key-pressed", key: { keyval, _, state in
            guard let shell = reference.value, shell.app.phase == .ready else { return false }
            let control = state.rawValue & GDK_CONTROL_MASK.rawValue != 0
            let typing = shell.isTyping
            switch Int32(keyval) {
            case GDK_KEY_space where !typing && !control:
                shell.app.player.togglePlayPause()
                return true
            case GDK_KEY_f where control:
                shell.sheet?.isOpen = false
                shell.select(.search)
                SearchPage.focus(shell.navigations[.search])
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
