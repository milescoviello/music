import CGtk
import Foundation

/// Signing in: the server's address, a username and a password, checked against the
/// server before anything is stored, so a typo surfaces here rather than as an empty
/// library later.
@MainActor
enum SetupPage {
    static func make(_ app: AppState) -> Widget {
        let address = EntryRow("Server address")
        address.inputPurpose(GTK_INPUT_PURPOSE_URL)
        let username = EntryRow("Username")
        let password = EntryRow("Password", password: true)
        let error = Label("", "error").wrap().visible(false)
        let spinner = Spinner().size(16).visible(false)
        let connect = Button("Connect", "suggested-action", "pill")
        connect.halign(GTK_ALIGN_CENTER).isSensitive = false

        let group = PreferencesGroup(
            "Navidrome Server",
            description: "Host and port. http:// is assumed unless you type https://."
        ) {
            address
            username
            password
        }

        func refresh() {
            connect.isSensitive = !address.text.trimmingCharacters(in: .whitespaces).isEmpty && !username.text.isEmpty
        }
        address.onChange { _ in refresh() }
        username.onChange { _ in refresh() }

        func submit() {
            guard connect.isSensitive else { return }
            guard let url = normalizedURL(address.text) else {
                error.text = "That address is not valid."
                error.isVisible = true
                return
            }
            error.isVisible = false
            connect.isSensitive = false
            spinner.isVisible = true
            let name = username.text
            let secret = password.text
            let alive = connect.liveness
            Task { @MainActor in
                do {
                    // Success replaces this page, so nothing here is touched after it.
                    try await app.signIn(baseURL: url, username: name, password: secret)
                } catch let failure {
                    guard alive.isAlive else { return }
                    error.text = failure.localizedDescription
                    error.isVisible = true
                    spinner.isVisible = false
                    refresh()
                }
            }
        }
        connect.onClicked { submit() }
        Signal.connect(password.widget, "entry-activated") { submit() }
        Signal.connect(username.widget, "entry-activated") { password.grabFocus() }
        Signal.connect(address.widget, "entry-activated") { username.grabFocus() }

        let status = StatusPage(
            icon: Desktop.applicationID,
            title: "Music",
            description: "Sign in to your Navidrome server.",
            child: Box.vertical(spacing: 18) {
                group
                error
                Box.horizontal(spacing: 8) {
                    spinner
                    connect
                }.halign(GTK_ALIGN_CENTER)
            }
        )
        // Typing goes straight into the address, as a sign-in form should.
        address.onMap { address.grabFocus() }
        let clamp = Clamp(status, maximum: 480)
        let toolbar = ToolbarView(content: ScrolledWindow(clamp).vexpand()).top(HeaderBar().title(WindowTitle("Set Up")))
        return toolbar
    }

    /// Accepts a bare `host:port` as well as a full URL.
    static func normalizedURL(_ text: String) -> URL? {
        var text = text.trimmingCharacters(in: .whitespaces)
        if !text.contains("://") { text = "http://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        return URL(string: text)
    }
}
