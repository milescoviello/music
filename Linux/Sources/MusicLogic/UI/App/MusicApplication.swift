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
    /// A quick start asked for on this launch's command line, run once the app is ready.
    @MainActor private static var pendingAction: QuickPlay?

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
        installQuickPlay(application)
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
            installQuickPlayActions(application)
        }
        Signal.connect(application, "activate") {
            if let shell {
                shell.present()
                return
            }
            let state = AppState()
            self.state = state
            // Where every stretch of the log starts: which build, on what.
            let launched = "launched \(SettingsPages.logVersion) on \(LogReport.currentSystem), network \(state.reachability.network)"
            Task { await Diagnostics.shared.record("app", launched) }
            let shell = Shell(application: OpaquePointer(application), app: state)
            self.shell = shell
            shell.present()
            // After the window, which a pairing code is shown over.
            RemotePairingPrompt.install()
            RemoteControlServer.shared.start(app: state)
            if let action = pendingAction {
                pendingAction = nil
                run(action)
            }
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

    /// `music --action=play-heavy-rotation` and the others in `QuickPlay`: the launcher's
    /// right-click menu, the desktop's Shortcuts. A second launch hands the action to the
    /// running app and exits; a first one starts the app and runs it once it is ready.
    @MainActor
    private static func installQuickPlay(_ application: UnsafeMutablePointer<AdwApplication>) {
        let names = QuickPlay.allCases.map(\.rawValue).joined(separator: ", ")
        g_application_add_main_option(
            application.cast(), "action", 0, GOptionFlags(rawValue: 0), G_OPTION_ARG_STRING,
            "Start playing: \(names)", "NAME"
        )
        Signal.connectStatus(application, "handle-local-options", pointer: { options in
            guard let options else { return -1 }
            let type = g_variant_type_new("s")
            defer { g_variant_type_free(type) }
            guard let value = g_variant_dict_lookup_value(options.cast(), "action", type) else { return -1 }
            defer { g_variant_unref(value) }
            let name = String(cString: g_variant_get_string(value, nil))
            guard let action = QuickPlay(rawValue: name) else {
                FileHandle.standardError.write("Unknown action \(name). One of: \(names)\n".data(using: .utf8)!)
                return 2
            }
            guard g_application_register(application.cast(), nil, nil) != 0 else { return 1 }
            if g_application_get_is_remote(application.cast()) != 0 {
                g_action_group_activate_action(application.opaque, action.rawValue, nil)
                if let bus = g_application_get_dbus_connection(application.cast()) {
                    g_dbus_connection_flush_sync(bus, nil, nil)
                }
                return 0
            }
            pendingAction = action
            return -1
        })
    }

    @MainActor
    private static func installQuickPlayActions(_ application: UnsafeMutablePointer<AdwApplication>) {
        for action in QuickPlay.allCases {
            let simple = g_simple_action_new(action.rawValue, nil)!
            Signal.connect(simple, "activate", pointer: { _ in run(action) })
            g_action_map_add_action(application.opaque, simple)
        }
    }

    @MainActor
    private static func run(_ action: QuickPlay) {
        guard let state else {
            pendingAction = action
            return
        }
        shell?.present()
        Task {
            for _ in 0..<100 where state.phase != .ready {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            let said = await state.quickPlay(action)
            await Diagnostics.shared.record("app", "\(action.title): \(said)")
        }
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
