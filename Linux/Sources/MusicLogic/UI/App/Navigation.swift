import CGtk
import Foundation

/// One stack of pages: what a tab's `NavigationStack` is on the phone. Each section in the
/// sidebar has its own, so going back to Library finds it where it was left.
@MainActor
final class Navigation {
    let view = NavigationView()
    let app: AppState
    weak var shell: Shell?
    /// The Search section's field, for Ctrl+F.
    var searchEntry: SearchEntry?

    init(app: AppState, shell: Shell?) {
        self.app = app
        self.shell = shell
        view.keep(self)
    }

    var env: Env { Env(app: app, navigation: self) }

    func setRoot(_ page: NavigationPage) {
        view.replace(with: page)
    }

    func push(_ destination: Destination) {
        view.push(Pages.make(destination, env: env))
    }

    func pop() {
        view.pop()
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
/// width.
@MainActor
enum Page {
    static func make(
        _ title: String,
        content: Widget,
        scrolls: Bool = true,
        clamp: Int32? = 1_000,
        tag: String? = nil,
        header: ((HeaderBar) -> Void)? = nil
    ) -> NavigationPage {
        let bar = HeaderBar()
        header?(bar)
        var body = content
        if let clamp { body = Clamp(content, maximum: clamp, threshold: min(clamp, 700)) }
        if scrolls { body = ScrolledWindow(body).vexpand() }
        let toolbar = ToolbarView(content: body).top(bar)
        return NavigationPage(toolbar, title: title, tag: tag)
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
