import CGtk
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
        // The phone's label: the books, the folder's name when one is chosen, a small chevron.
        let name = Label("", "scope-name")
        let label = Box.horizontal(spacing: 3) {
            Icon(Symbol.icon("books.vertical"), size: 20)
            name
            Icon(Symbol.icon("chevron.down"), size: 11)
        }
        gtk_button_set_child(button.widget.cast(), label.widget)
        button.tooltip("Library")
        button.observe {
            button.isVisible = store.isSwitchable
            if case .folder = store.scope { name.text = store.scope.shortName } else { name.text = "" }
            name.isVisible = !name.text.isEmpty
        }
        return button
    }
}
