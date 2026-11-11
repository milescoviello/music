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
    @MainActor private static var pendingCommand: QuickCommand?

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
            PlayOn.players = RemotePlayers(appState: state, browser: AvahiBrowser())
            // Where every stretch of the log starts: which build, on what.
            let launched = "launched \(SettingsPages.logVersion) on \(LogReport.currentSystem), network \(state.reachability.network)"
            Task { await Diagnostics.shared.record("app", launched) }
            let shell = Shell(application: OpaquePointer(application), app: state)
            self.shell = shell
            shell.present()
            // After the window, which a pairing code is shown over.
            RemotePairingPrompt.install()
            RemoteControlServer.shared.volume = ({ OutputVolume.shared.level }, { OutputVolume.shared.level = $0 })
            RemoteControlServer.shared.start(app: state, advertiser: Avahi())
            if let command = pendingCommand {
                pendingCommand = nil
                run(command)
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

    /// `music --action=play-heavy-rotation` and the others in `QuickPlay` (with `--mix=N`
    /// for Made for You), `--play-playlist=NAME`, `--play-artist=NAME`, `--play-album=NAME`
    /// (each with `--shuffle`), `--make-playlist=VIBE`, and for the song playing `--love`,
    /// `--song-radio` and `--add-to-playlist=NAME`:
    /// the launcher's right-click menu, the desktop's shortcuts, the phone's Siri. A second
    /// launch hands the command to the running app and exits; a first one starts the app
    /// and runs it once it is ready.
    @MainActor
    private static func installQuickPlay(_ application: UnsafeMutablePointer<AdwApplication>) {
        let names = QuickPlay.allCases.map(\.rawValue).joined(separator: ", ")
        let options: [(String, GOptionArg, String, String?)] = [
            ("action", G_OPTION_ARG_STRING, "Start playing: \(names)", "NAME"),
            ("mix", G_OPTION_ARG_INT, "With --action=play-made-for-you: which mix, from 1", "N"),
            ("play-playlist", G_OPTION_ARG_STRING, "Play the playlist with this name", "NAME"),
            ("play-artist", G_OPTION_ARG_STRING, "Play the artist with this name", "NAME"),
            ("play-album", G_OPTION_ARG_STRING, "Play the album with this name", "NAME"),
            ("shuffle", G_OPTION_ARG_NONE, "With --play-playlist, --play-artist or --play-album: shuffled", nil),
            ("make-playlist", G_OPTION_ARG_STRING, "Ask Hermes for a playlist from a description", "VIBE"),
            ("love", G_OPTION_ARG_NONE, "Love the song playing", nil),
            ("song-radio", G_OPTION_ARG_NONE, "Start a radio from the song playing", nil),
            ("add-to-playlist", G_OPTION_ARG_STRING, "Add the song playing to the playlist with this name", "NAME"),
        ]
        for (name, kind, help, value) in options {
            g_application_add_main_option(application.cast(), name, 0, GOptionFlags(rawValue: 0), kind, help, value)
        }
        Signal.connectStatus(application, "handle-local-options", pointer: { options in
            guard let options else { return -1 }
            func string(_ key: String) -> String? {
                guard let value = g_variant_dict_lookup_value(options.cast(), key, cgtk_type_string()) else { return nil }
                defer { g_variant_unref(value) }
                return String(cString: g_variant_get_string(value, nil))
            }
            var mix: Int32 = 1
            if let value = g_variant_dict_lookup_value(options.cast(), "mix", nil) {
                mix = g_variant_get_int32(value)
                g_variant_unref(value)
            }
            let shuffled = g_variant_dict_contains(options.cast(), "shuffle") != 0

            let command: QuickCommand
            if let name = string("play-playlist") {
                command = .playlist(name: name, shuffled: shuffled)
            } else if let name = string("play-artist") {
                command = .artist(name: name, shuffled: shuffled)
            } else if let name = string("play-album") {
                command = .album(name: name, shuffled: shuffled)
            } else if g_variant_dict_contains(options.cast(), "love") != 0 {
                command = .song(.love)
            } else if g_variant_dict_contains(options.cast(), "song-radio") != 0 {
                command = .song(.radio)
            } else if let name = string("add-to-playlist") {
                command = .song(.addToPlaylist, playlist: name)
            } else if let vibe = string("make-playlist") {
                command = .makePlaylist(vibe: vibe)
            } else if let name = string("action") {
                guard let action = QuickPlay(rawValue: name) else {
                    FileHandle.standardError.write("Unknown action \(name). One of: \(names)\n".data(using: .utf8)!)
                    return 2
                }
                command = .play(action, mix: Int(mix))
            } else {
                return -1
            }
            guard g_application_register(application.cast(), nil, nil) != 0 else { return 1 }
            if g_application_get_is_remote(application.cast()) != 0 {
                g_action_group_activate_action(application.opaque, "command", g_variant_new_string(command.encoded))
                if let bus = g_application_get_dbus_connection(application.cast()) {
                    g_dbus_connection_flush_sync(bus, nil, nil)
                }
                return 0
            }
            pendingCommand = command
            return -1
        })
    }

    @MainActor
    private static func installQuickPlayActions(_ application: UnsafeMutablePointer<AdwApplication>) {
        for action in QuickPlay.allCases {
            let simple = g_simple_action_new(action.rawValue, nil)!
            Signal.connect(simple, "activate", pointer: { _ in run(.play(action)) })
            g_action_map_add_action(application.opaque, simple)
        }
        // Everything a second launch can say, as one string: see `QuickCommand.encoded`.
        let command = g_simple_action_new("command", cgtk_type_string())!
        Signal.connect(command, "activate", pointer: { parameter in
            guard let parameter else { return }
            let text = String(cString: g_variant_get_string(OpaquePointer(parameter), nil))
            if let decoded = QuickCommand(encoded: text) { run(decoded) }
        })
        g_action_map_add_action(application.opaque, command)
    }

    @MainActor
    private static func run(_ command: QuickCommand) {
        guard let state else {
            pendingCommand = command
            return
        }
        shell?.present()
        Task {
            for _ in 0..<100 where state.phase != .ready {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            let said = await state.run(command)
            await Diagnostics.shared.record("app", "\(command.title): \(said)")
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
