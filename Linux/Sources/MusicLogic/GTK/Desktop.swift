import CGtk

/// The running application and its window, for the few things outside the UI that need
/// them: the idle inhibitor, MPRIS's Raise, the notification of a finished request.
@MainActor
enum Desktop {
    static var application: OpaquePointer?
    static var window: UnsafeMutablePointer<GtkWidget>?

    static let applicationID = "com.milescoviello.Music"

    /// Brings the window forward, for MPRIS's Raise and a second launch.
    static func raise() {
        guard let window else { return }
        gtk_window_present(window.cast())
    }
}
