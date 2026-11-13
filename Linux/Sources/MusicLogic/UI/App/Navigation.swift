import CGtk
import Foundation
import Observation

/// The window's history, a browser's: every page opened, in the order it was opened,
/// whichever section it was opened in, with Back and Forward through all of it. Opening
/// an artist from the player or from Search, Back comes back there, not to wherever the
/// Library section was last left.
///
/// A page lives as long as the history holds it, so going back or forward finds it
/// scrolled where it was and its search still typed; each section's first page lives as
/// long as the window. Pages are shown in a plain stack, without a transition.
@MainActor
@Observable
final class Navigation {
    struct Entry {
        let page: NavigationPage
        let name: String
        let section: Shell.Section
    }

    @ObservationIgnored let view = Stack(transition: GTK_STACK_TRANSITION_TYPE_NONE)
    @ObservationIgnored let app: AppState
    @ObservationIgnored weak var shell: Shell?
    /// The Search section's field, for Ctrl+F.
    @ObservationIgnored var searchEntry: SearchEntry?
    private(set) var entries: [Entry] = []
    private(set) var index = -1
    /// One page at a time, the sidebar folded away: Back with nothing behind it shows the
    /// sidebar.
    var isCollapsed = false
    /// Counts pages that have said what cover they show (`NavigationPage.coverArt`), so
    /// the backdrop can follow one that loads late.
    private(set) var coverChanges = 0
    @ObservationIgnored private var roots: [Shell.Section: Entry] = [:]
    @ObservationIgnored private var opened = 0
    /// Enough to go back through a long evening's browsing; each page kept costs memory.
    private static let limit = 60

    init(app: AppState, shell: Shell?) {
        self.app = app
        self.shell = shell
        gtk_stack_set_hhomogeneous(view.widget.cast(), 0)
        gtk_stack_set_vhomogeneous(view.widget.cast(), 0)
        view.keep(self)
    }

    var env: Env { Env(app: app, navigation: self) }

    var current: Entry? { entries.indices.contains(index) ? entries[index] : nil }
    var section: Shell.Section { current?.section ?? .home }
    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index < entries.count - 1 }

    /// A section's first page, kept for the window's life.
    func coverChanged() {
        coverChanges += 1
    }

    func addRoot(_ section: Shell.Section, _ page: NavigationPage) {
        let entry = Entry(page: page, name: section.rawValue, section: section)
        roots[section] = entry
        view.add(page, name: entry.name)
        addButtons(to: page)
    }

    /// Opens a page after the one showing, in the same section.
    func push(_ destination: Destination) {
        let page = Pages.make(destination, env: env)
        opened += 1
        let entry = Entry(page: page, name: "page-\(opened)", section: section)
        view.add(page, name: entry.name)
        addButtons(to: page)
        go(to: entry)
    }

    /// A section from the sidebar: its first page, as a new step in the history. On that
    /// page already, back to the top of it.
    func open(_ section: Shell.Section) {
        guard let root = roots[section] else { return }
        if current?.name == root.name {
            root.page.scroller?.scrollToTop()
            return
        }
        go(to: root)
    }

    func goBack() {
        guard canGoBack else {
            if isCollapsed { shell?.showSidebar() }
            return
        }
        index -= 1
        show()
    }

    func goForward() {
        guard canGoForward else { return }
        index += 1
        show()
    }

    /// A page closing itself once it has done its work.
    func pop() {
        goBack()
    }

    /// What was ahead is forgotten, as a browser forgets it.
    private func go(to entry: Entry) {
        var dropped = Array(entries[(index + 1)...])
        entries.removeSubrange((index + 1)...)
        entries.append(entry)
        if entries.count > Self.limit {
            dropped += entries.prefix(entries.count - Self.limit)
            entries.removeFirst(entries.count - Self.limit)
        }
        index = entries.count - 1
        show()
        let kept = Set(entries.map(\.name))
        for old in dropped where roots[old.section]?.name != old.name && !kept.contains(old.name) {
            view.remove(old.page)
        }
    }

    private func show() {
        guard let entry = current else { return }
        view.visibleName = entry.name
        shell?.showContent()
    }

    /// Back and Forward at the start of every page's header bar. The header bar's own
    /// back button is off: it only knows the pages of a navigation view.
    func addButtons(to page: NavigationPage) {
        guard let header = page.header ?? Self.findHeader(in: page.widget) else { return }
        let back = Button(icon: "go-previous-symbolic", "flat") { [weak self] in self?.goBack() }
        let forward = Button(icon: "go-next-symbolic", "flat") { [weak self] in self?.goForward() }
        back.tooltip("Back")
        forward.tooltip("Forward")
        let buttons = Box.horizontal(spacing: 0) {
            back
            forward
        }.css("history-buttons")
        buttons.observe { [weak self] in
            guard let self else { return }
            back.isSensitive = canGoBack || isCollapsed
            forward.isSensitive = canGoForward
        }
        header.showsBackButton(false).start(buttons)
    }

    /// The header bar of a page not made by `Page.make`: Settings, a genre.
    private static func findHeader(in widget: UnsafeMutablePointer<GtkWidget>, depth: Int = 0) -> HeaderBar? {
        var child = gtk_widget_get_first_child(widget)
        while let current = child {
            let instance = UnsafeMutableRawPointer(current).assumingMemoryBound(to: GTypeInstance.self)
            if g_type_check_instance_is_a(instance, adw_header_bar_get_type()) != 0 {
                return HeaderBar(existing: current)
            }
            if depth < 4, let found = findHeader(in: current, depth: depth + 1) { return found }
            child = gtk_widget_get_next_sibling(current)
        }
        return nil
    }
}

/// What a screen is built with: the app, and where to open things. The phone's SwiftUI
/// environment, passed by hand.
@MainActor
struct Env {
    let app: AppState
    let navigation: Navigation

    var player: PlaybackController { app.player }
    var artwork: ArtworkStore { app.artwork }

    func open(_ destination: Destination) {
        navigation.push(destination)
    }

    func toast(_ text: String) {
        navigation.shell?.toast(text)
    }

    /// Plays songs from a screen, and opens the player if the setting says to.
    func play(_ songs: [Song], from index: Int = 0, source: String, shuffled: Bool = false) {
        player.play(songs: songs, startingAt: index, source: source, shuffled: shuffled)
    }
}

/// The page every screen is: a header bar over scrolling content held to a readable
/// width, with the page's name large at the top of it, as on the phone. The header bar
/// shows the name small only once the large one has scrolled away. A page that opens
/// with a title of its own (an album's, an artist's) asks for no heading.
@MainActor
enum Page {
    static func make(
        _ title: String,
        content: Widget,
        scrolls: Bool = true,
        clamp: Int32? = 1_160,
        heading: Bool = true,
        tag: String? = nil,
        header: ((HeaderBar) -> Void)? = nil
    ) -> NavigationPage {
        let bar = HeaderBar()
        header?(bar)
        var body = content
        let large = heading && scrolls ? Label(title, "page-heading").xalign(0).ellipsize() : nil
        if let large {
            body = Box.vertical(spacing: 0) {
                large.margins(top: 4, bottom: 14, start: 12, end: 12)
                content
            }
        }
        if let clamp { body = Clamp(body, maximum: clamp, threshold: min(clamp, 700)) }
        var scroller: ScrolledWindow?
        if scrolls {
            let window = ScrolledWindow(body).vexpand()
            scroller = window
            body = window
        }
        let toolbar = ToolbarView(content: body).top(bar)
        let page = NavigationPage(toolbar, title: title, tag: tag)
        page.header = bar
        page.scroller = scroller
        if let large, let scroller {
            let small = WindowTitle(title)
            bar.title(small)
            small.opacity(0)
            let adjustment = scroller.verticalAdjustment
            Signal.connect(adjustment, "value-changed") {
                small.opacity(gtk_adjustment_get_value(adjustment) > 48 ? 1 : 0)
            }
            _ = large
        }
        return page
    }
}

/// A slot that shows a spinner until its content has loaded, then the content — or a
/// status page saying why there is none.
@MainActor
final class Loader {
    let bin = Bin()
    private var generation = 0

    init() {
        bin.child = Spinner().size(32).halign(GTK_ALIGN_CENTER).valign(GTK_ALIGN_CENTER).margin(48)
        bin.keep(self)
    }

    /// Runs `load`, then puts `build`'s widget in the slot. A newer call wins over an
    /// older one still running.
    func run<T>(
        _ load: @escaping @MainActor () async -> T?,
        failure: @escaping @MainActor () -> Widget = { Loader.offline() },
        build: @escaping @MainActor (T) -> Widget
    ) {
        generation += 1
        let current = generation
        let reference = WeakReference(self)
        Task { @MainActor in
            let value = await load()
            guard let loader = reference.value, loader.generation == current else { return }
            loader.bin.child = value.map(build) ?? failure()
        }
    }

    func show(_ widget: Widget) {
        generation += 1
        bin.child = widget
    }

    static func offline() -> Widget {
        StatusPage(
            icon: "network-offline-symbolic",
            title: "Couldn't Load",
            description: "The server didn't answer. Downloaded music still plays."
        )
    }

    static func empty(_ title: String, icon: String = "folder-music-symbolic", description: String? = nil) -> Widget {
        StatusPage(icon: icon, title: title, description: description)
    }
}
