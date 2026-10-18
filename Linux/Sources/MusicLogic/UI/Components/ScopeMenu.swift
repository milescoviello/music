import Foundation

/// The library switch, for servers with more than one music folder: a header-bar menu
/// whose items are the folders. Absent on a single-library server.
@MainActor
enum ScopeMenu {
    static func make(_ app: AppState) -> Widget {
        let store = app.scope
        let button = MenuButton(icon: "folder-open-symbolic", "flat") {
            Menu([[.choice(
                "Library",
                options: store.options.map { ($0.cacheKey, $0.shortName) },
                selected: store.scope.cacheKey
            ) { key in
                if let option = store.options.first(where: { $0.cacheKey == key }) { store.scope = option }
            }]])
        }
        button.tooltip("Library")
        button.observe { button.isVisible = store.isSwitchable }
        return button
    }
}
