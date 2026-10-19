import CGtk
import Foundation

/// The entry point: a libadwaita application whose GLib main loop also runs Swift's main
/// actor, and which opens one window over one `AppState`.
///
/// A second launch reaches the first, as GApplication does by default: it raises the
/// window rather than starting a second player on the same sound card.
public enum MusicApplication {
    @MainActor private static var state: AppState?
    @MainActor private static var shell: Shell?

    @MainActor
    public static func run() {
        MainLoop.install()
        g_set_application_name("Music")
        // X11 matches the window to its launcher entry by class, which comes from this.
        g_set_prgname(Desktop.applicationID)
        gtk_window_set_default_icon_name(Desktop.applicationID)

        let application = adw_application_new(Desktop.applicationID, GApplicationFlags(rawValue: 0))!
        Desktop.application = OpaquePointer(application)
        persistDefaults()
        // Logging out or `kill` sends SIGTERM, which would otherwise end the process
        // without "shutdown" and lose the queue position and unsaved settings.
        for signal in [SIGTERM, SIGINT, SIGHUP] {
            g_unix_signal_add(signal, { application in
                g_application_quit(application?.assumingMemoryBound(to: GApplication.self))
                return 0
            }, UnsafeMutableRawPointer(application))
        }

        Signal.connect(application, "startup") {
            Style.install()
            BundledIcons.install()
            installAccelerators(application)
        }
        Signal.connect(application, "activate") {
            if let shell {
                shell.present()
                return
            }
            let state = AppState()
            self.state = state
            let shell = Shell(application: OpaquePointer(application), app: state)
            self.shell = shell
            shell.present()
        }
        Signal.connect(application, "shutdown") {
            // The phone's backgrounding, which on a desktop is quitting: termination while
            // paused is what loses a queue position.
            shell?.saveSize()
            guard let state else { return }
            state.player.persistNow()
            state.history.saveNow()
            state.downloads.flushCatalog()
            state.screenAwake.release()
            UserDefaults.standard.synchronize()
        }

        let arguments = CommandLine.arguments
        var pointers = arguments.map { strdup($0) }
        let status = g_application_run(application.cast(), Int32(pointers.count), &pointers)
        pointers.forEach { free($0) }
        exit(status)
    }

    /// Foundation on Linux keeps UserDefaults in memory until told to write them out (to
    /// `~/.config/music.plist`) — on Darwin cfprefsd does that behind the app's back — so
    /// every setting, history and layout would be lost with the process. A write when
    /// nothing changed is a no-op.
    private static func persistDefaults() {
        g_timeout_add_seconds(3, { _ in
            UserDefaults.standard.synchronize()
            return 1
        }, nil)
    }

    @MainActor
    private static func installAccelerators(_ application: UnsafeMutablePointer<AdwApplication>) {
        let quit = g_simple_action_new("quit", nil)!
        Signal.connect(quit, "activate", pointer: { _ in
            g_application_quit(application.cast())
        })
        g_action_map_add_action(application.opaque, quit)
        "<Control>q".withCString { accel in
            var accels: [UnsafePointer<CChar>?] = [accel, nil]
            gtk_application_set_accels_for_action(application.cast(), "app.quit", &accels)
        }
    }
}
