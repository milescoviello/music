import CGtk
import Foundation
import Observation

/// Each tab's own history, as the phone keeps a navigation stack per tab: Back goes to
/// the page before in the same tab, and leaving a tab and coming back finds it where it
/// was left. A page opened from the player or from a menu opens in the tab showing.
///
/// A page lives as long as its tab's history holds it, so going back finds it scrolled
/// where it was; each tab's first page lives as long as the window. Pages are shown in a
/// plain stack, without a transition.
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
    /// The Search tab's field, for Ctrl+F.
    @ObservationIgnored var searchEntry: SearchEntry?
    private(set) var histories: [Shell.Section: [Entry]] = [:]
    private(set) var section: Shell.Section = .home {
        didSet { if oldValue != section, oldValue != .search { previousTab = oldValue } }
    }
    /// The tab before Search, which Search's bar offers the way back to, as iOS 26 does.
    private(set) var previousTab: Shell.Section = .home
    /// Counts pages that have said what cover they show (`NavigationPage.coverArt`).
    private(set) var coverChanges = 0
    @ObservationIgnored private var opened = 0
    /// Enough to go back through an evening's browsing; each page kept holds its covers
    /// and watches what it shows, so not without end.
    private static let limit = 30

    init(app: AppState, shell: Shell?) {
        self.app = app
        self.shell = shell
        gtk_stack_set_hhomogeneous(view.widget.cast(), 0)
        gtk_stack_set_vhomogeneous(view.widget.cast(), 0)
        view.css("pages")
        view.keep(self)
    }

    var env: Env { Env(app: app, navigation: self) }

    var current: Entry? { histories[section]?.last }
    var canGoBack: Bool { (histories[section]?.count ?? 0) > 1 }

    func coverChanged() {
        coverChanges += 1
    }

    /// A tab's first page, kept for the window's life.
    func addRoot(_ section: Shell.Section, _ page: NavigationPage) {
        let entry = Entry(page: page, name: section.rawValue, section: section)
        histories[section] = [entry]
        view.add(page, name: entry.name)
    }

    /// Opens a page after the one showing, in the same tab.
    func push(_ destination: Destination) {
        let page = Pages.make(destination, env: env)
        opened += 1
        let entry = Entry(page: page, name: "page-\(opened)", section: section)
        view.add(page, name: entry.name)
        addBackButton(to: page)
        var history = histories[section] ?? []
        history.append(entry)
        if history.count > Self.limit {
            let dropped = history.remove(at: 1)
            view.remove(dropped.page)
        }
        histories[section] = history
        show()
    }

    /// A tab from the tab bar: where it was left. On it already, back to its first page,
    /// and on that, to the top, as tapping the tab does on the phone.
    func open(_ section: Shell.Section) {
        guard let history = histories[section], let root = history.first else { return }
        guard section == self.section else {
            self.section = section
            show()
            return
        }
        if history.count > 1 {
            popToRoot()
        } else {
            root.page.scroller?.scrollToTop()
        }
    }

    /// A tab, left as it was: where a jump lands before pushing its page.
    func switchTo(_ section: Shell.Section) {
        guard histories[section] != nil, section != self.section else { return }
        self.section = section
        show()
    }

    func goBack() {
        guard var history = histories[section], history.count > 1 else { return }
        let dropped = history.removeLast()
        histories[section] = history
        show()
        view.remove(dropped.page)
    }

    /// A page closing itself once it has done its work.
    func pop() {
        goBack()
    }

    func popToRoot() {
        guard var history = histories[section], history.count > 1 else { return }
        let dropped = history.dropFirst()
        history.removeSubrange(1...)
        histories[section] = history
        show()
        for entry in dropped { view.remove(entry.page) }
    }

    private func show() {
        guard let entry = current else { return }
        view.visibleName = entry.name
    }

    /// The phone's back button: a glass circle at the start of a pushed page's bar.
    func addBackButton(to page: NavigationPage) {
        guard let header = page.header ?? Self.findHeader(in: page.widget) else { return }
        let back = Button(icon: "go-previous-symbolic", "glass", "circular", "back-button") { [weak self] in
            self?.goBack()
        }
        back.tooltip("Back")
        header.showsBackButton(false).leading(back)
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
    /// The tab bar (54), the mini player above it (56) and their gaps.
    static let chromeClearance: Int32 = 150

    static func make(
        _ title: String,
        content: Widget,
        scrolls: Bool = true,
        clamp: Int32? = 1_600,
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
                large.margins(top: 2, bottom: 10, start: 16, end: 16)
                content
            }
        }
        if let clamp { body = Clamp(body, maximum: clamp, threshold: min(clamp, 700)) }
        // Room at the end for the mini player and tab bar floating over the page, so the
        // last row scrolls clear of them rather than ending under them.
        if scrolls { body = Box.vertical(spacing: 0) { body }.margins(bottom: Page.chromeClearance) }
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
