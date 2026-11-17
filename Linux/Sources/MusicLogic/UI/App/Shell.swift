import CGtk
import Foundation

/// The window, as the phone's: each tab's pages (`Navigation`), the mini player and the
/// glass tab bar floating over them at the bottom, and the full player sliding up over it
/// all. The same at any width; only the pages' content widens.
@MainActor
final class Shell {
    enum Section: String, CaseIterable {
        case home, library, downloads, search, settings

        /// The phone's tabs, in its order. Settings is a page, opened from Home's gear.
        static let tabs: [Section] = [.home, .library, .downloads, .search]
        /// The ones in the glass bar; Search is the circle beside it.
        static let barTabs: [Section] = [.home, .library, .downloads]

        var title: String {
            switch self {
            case .home: return "Home"
            case .library: return "Library"
            case .search: return "Search"
            case .downloads: return "Downloads"
            case .settings: return "Settings"
            }
        }

        /// The phone's tab symbol.
        var symbol: String {
            switch self {
            case .home: return "house"
            case .library: return "square.stack"
            case .search: return "magnifyingglass"
            case .downloads: return "arrow.down.circle"
            case .settings: return "gearshape"
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
    private var sheet: PlayerLayer?
    /// The full player, for what opens it showing one of its modes.
    private(set) var player: PhonePlayer?
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
        for section in Section.tabs {
            navigation.addRoot(section, Pages.root(section, env: navigation.env))
        }
        installHistoryButtons()

        let pages = Overlay(navigation.view.vexpand())
        pages.add(BottomChrome(app: app, shell: self, navigation: navigation).root)
        let main = ToolbarView(content: pages)
        main.top(RemoteQueueBar.make(app))
        main.top(offlineBanner())

        let player = PhonePlayer(app: app, env: navigation.env)
        self.player = player
        let sheet = PlayerLayer(content: main, player: player.root)
        self.sheet = sheet
        sheet.onOpenChanged { [app] open in
            if app.navigator.showsPlayer != open { app.navigator.showsPlayer = open }
        }

        let reference = WeakReference(self)
        sheet.root.observe { [app] in
            let hasQueue = app.player.hasQueue
            let shows = app.navigator.showsPlayer
            guard let shell = reference.value, let sheet = shell.sheet else { return }
            sheet.canOpen = hasQueue
            sheet.isOpen = shows && hasQueue
        }
        // The backdrop's colours, which only the player shows (the pages are black, as on
        // the phone): the playing song's. The accent stays the phone's one tint.
        sheet.root.observe { [app] in
            let playing = app.player.currentSong?.coverArt
            guard let shell = reference.value else { return }
            shell.backdrop.show(cover: playing, accent: false)
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

    /// A tab from the tab bar, a menu or a key: where it was left; on it already, its first
    /// page. Settings, which the phone opens from Home, opens as a page in the tab showing.
    func select(_ section: Section) {
        if section == .settings {
            navigation?.push(.settings)
            return
        }
        navigation?.open(section)
        // Search again, from the bar or a key: the field takes the keyboard, as it does
        // when the page first shows.
        if section == .search { navigation?.searchEntry?.grabFocus() }
    }

    private func takeNavigationRequests() {
        let requests = app.navigator.takeRequests()
        guard !requests.isEmpty, let navigation else { return }
        // A jump out of the player opens in Library, as on the phone, where the way back is
        // ordinary navigation.
        if app.navigator.wantsLibraryTab {
            app.navigator.didSelectLibraryTab()
            navigation.switchTo(.library)
        }
        for destination in requests { navigation.push(destination) }
    }

    /// The mouse's back button, anywhere in the window. A gesture for that button only: one
    /// listening to every button, ahead of everything else, had a part in every click.
    private func installHistoryButtons() {
        let reference = WeakReference(self)
        let gesture = gtk_gesture_click_new()!
        gtk_gesture_single_set_button(gesture.cast(), 8)
        Signal.connect(gesture, "pressed", press: { _, _, _ in
            guard let shell = reference.value, shell.sheet?.isOpen != true else { return }
            shell.navigation?.goBack()
        })
        gtk_widget_add_controller(window.widget, gesture.cast())
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
    /// Ctrl+Left and Right skip; Alt+Left goes back; Escape closes the player.
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
            case GDK_KEY_Back:
                shell.navigation?.goBack()
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
