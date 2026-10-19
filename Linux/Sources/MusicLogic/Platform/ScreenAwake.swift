import CGtk
import Foundation
import Observation

/// Keeps the screen from blanking while the app is open, as the phone's player menu
/// offers for reading lyrics with the phone propped up.
///
/// The phone's idle-timer flag becomes an idle inhibitor: GTK asks the session — GNOME,
/// Plasma, or the portal — not to blank or lock while it is held. It is released when the
/// setting is turned off and when the app quits, so it can never outlive the window.
@MainActor
@Observable
final class ScreenAwake {
    private let key = "screen.keepAwake"
    @ObservationIgnored private var cookie: guint = 0

    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: key)
            apply()
        }
    }

    init() {
        isEnabled = UserDefaults.standard.bool(forKey: key)
    }

    /// Call once the window exists, and whenever the setting changes. Idempotent.
    func apply() {
        guard isEnabled else {
            release()
            return
        }
        guard cookie == 0, let application = Desktop.application else { return }
        cookie = gtk_application_inhibit(
            application.cast(),
            Desktop.window?.cast(),
            GTK_APPLICATION_INHIBIT_IDLE,
            "Keeping the screen on"
        )
    }

    func release() {
        guard cookie != 0, let application = Desktop.application else { return }
        gtk_application_uninhibit(application.cast(), cookie)
        cookie = 0
    }
}
