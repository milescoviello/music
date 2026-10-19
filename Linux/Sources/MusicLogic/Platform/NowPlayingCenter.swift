import CGtk
import Foundation

/// The desktop's lock screen and Control Centre: MPRIS over D-Bus.
///
/// Plasma's media controls, GNOME's, the keyboard's media keys, `playerctl` and a paired
/// phone's KDE Connect all drive whatever player publishes `org.mpris.MediaPlayer2`, so
/// this one object is every remote control the desktop has. Same surface as the phone's
/// version, so `PlaybackController` publishes to it unchanged.
///
/// The phone's rule about elapsed time holds here too: it is published on state
/// transitions only, with the rate, and clients extrapolate. `Position` is computed from
/// those when asked, and `Seeked` is sent when an update lands somewhere extrapolation
/// would not have — a seek — which is what MPRIS asks for instead of a timer.
@MainActor
final class NowPlayingCenter {
    var onPlay: (() -> Void)?
    var onPause: (() -> Void)?
    var onToggle: (() -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onSeek: ((Double) -> Void)?

    private struct State {
        var song: Song?
        var elapsed: Double = 0
        var stamp = Date.now
        var duration: Double = 0
        var isPlaying = false
        var speed: Double = 1
        var queueIndex = 0
        var queueCount = 0
        var artURL: URL?
        var artSongID: String?
    }

    private var state = State()
    private var connection: OpaquePointer?
    private var owner: guint = 0

    private static let objectPath = "/org/mpris/MediaPlayer2"
    private static let busName = "org.mpris.MediaPlayer2.Music"

    init() {
        let data = Unmanaged.passUnretained(self).toOpaque()
        owner = g_bus_own_name(
            G_BUS_TYPE_SESSION,
            Self.busName,
            GBusNameOwnerFlags(rawValue: 0),
            { connection, _, data in
                guard let connection, let data else { return }
                let center = Unmanaged<NowPlayingCenter>.fromOpaque(data).takeUnretainedValue()
                nonisolated(unsafe) let pointer = connection
                MainActor.assumeIsolated { center.register(on: pointer) }
            },
            nil,
            nil,
            data,
            nil
        )
    }

    // MARK: - Publishing

    func update(
        song: Song,
        elapsed: Double,
        duration: Double,
        isPlaying: Bool,
        speed: Float = 1,
        queueIndex: Int,
        queueCount: Int
    ) {
        let previous = state
        let sameSong = previous.song?.id == song.id

        state.song = song
        state.elapsed = elapsed
        state.stamp = .now
        state.duration = duration
        state.isPlaying = isPlaying
        state.speed = Double(speed)
        state.queueIndex = queueIndex
        state.queueCount = queueCount
        // Artwork belongs to the previous track until the new one arrives.
        if state.artSongID != song.id {
            state.artURL = nil
            state.artSongID = nil
        }

        var changed: [String: OpaquePointer] = [:]
        if !sameSong || previous.duration != duration { changed["Metadata"] = metadata() }
        if previous.isPlaying != isPlaying || previous.song == nil { changed["PlaybackStatus"] = playbackStatus() }
        if previous.speed != state.speed { changed["Rate"] = g_variant_new_double(state.speed) }
        if previous.queueIndex != queueIndex || previous.queueCount != queueCount || previous.song == nil {
            changed["CanGoNext"] = g_variant_new_boolean(canGoNext ? 1 : 0)
            changed["CanGoPrevious"] = g_variant_new_boolean(1)
        }
        emitChanged(changed)

        // A position no extrapolation would have reached: a seek, or a resume elsewhere.
        if sameSong {
            let expected = Self.position(previous, at: state.stamp)
            if abs(expected - elapsed) > 1 { emitSeeked(elapsed) }
        }
    }

    /// Written to a file, since an MPRIS client is handed a URL rather than pixels, and
    /// the server's URL would hand every client on the desktop the account's token.
    func setArtwork(_ image: Texture, songID: String? = nil) {
        let directory = Paths.caches.appendingPathComponent("NowPlaying", isDirectory: true)
        let name = (songID ?? "current").replacingOccurrences(of: "/", with: "_")
        let url = directory.appendingPathComponent("\(name).png")
        Task {
            let written = await Task.detached(priority: .utility) { () -> Bool in
                try? FileManager.default.removeItem(at: directory)
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                guard let data = image.pngData() else { return false }
                return (try? data.write(to: url, options: .atomic)) != nil
            }.value
            guard written, state.song?.id == songID || songID == nil else { return }
            state.artURL = url
            state.artSongID = songID
            emitChanged(["Metadata": metadata()])
        }
    }

    func clear() {
        state = State()
        emitChanged(["Metadata": metadata(), "PlaybackStatus": playbackStatus()])
    }

    // MARK: - Values

    private var canGoNext: Bool { state.queueIndex + 1 < state.queueCount }

    private static func position(_ state: State, at time: Date) -> Double {
        guard state.isPlaying else { return state.elapsed }
        let moved = state.elapsed + time.timeIntervalSince(state.stamp) * state.speed
        return state.duration > 0 ? min(moved, state.duration) : moved
    }

    private func playbackStatus() -> OpaquePointer {
        let status = state.song == nil ? "Stopped" : (state.isPlaying ? "Playing" : "Paused")
        return g_variant_new_string(status)
    }

    private static func trackPath(_ songID: String?) -> String {
        guard let songID else { return "/org/mpris/MediaPlayer2/TrackList/NoTrack" }
        let safe = songID.unicodeScalars.map { scalar -> String in
            CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII ? String(scalar) : "_"
        }.joined()
        return "/com/milescoviello/Music/track/t\(safe)"
    }

    private func metadata() -> OpaquePointer {
        var entries: [(String, OpaquePointer)] = [
            ("mpris:trackid", g_variant_new_object_path(Self.trackPath(state.song?.id))),
        ]
        if let song = state.song {
            entries.append(("xesam:title", g_variant_new_string(song.title)))
            if let artist = song.artist {
                entries.append(("xesam:artist", Self.strings([artist])))
            }
            if let album = song.album {
                entries.append(("xesam:album", g_variant_new_string(album)))
            }
            if let track = song.track {
                entries.append(("xesam:trackNumber", g_variant_new_int32(Int32(track))))
            }
            let length = state.duration > 0 ? state.duration : Double(song.duration ?? 0)
            entries.append(("mpris:length", g_variant_new_int64(gint64(length * 1_000_000))))
            if let art = state.artURL {
                entries.append(("mpris:artUrl", g_variant_new_string(art.absoluteString)))
            }
        }
        return Self.dictionary(entries)
    }

    private static func strings(_ values: [String]) -> OpaquePointer {
        var children = values.map { g_variant_new_string($0) }
        return g_variant_new_array(cgtk_variant_type("s"), &children, gsize(children.count))
    }

    /// An `a{sv}`.
    private static func dictionary(_ entries: [(String, OpaquePointer)]) -> OpaquePointer {
        var children = entries.map { key, value in
            g_variant_new_dict_entry(g_variant_new_string(key), g_variant_new_variant(value))
        }
        return g_variant_new_array(cgtk_variant_type("{sv}"), &children, gsize(children.count))
    }

    private func property(_ interface: String, _ name: String) -> OpaquePointer? {
        switch (interface, name) {
        case (_, "CanQuit"), (_, "CanRaise"): return g_variant_new_boolean(1)
        case (_, "HasTrackList"): return g_variant_new_boolean(0)
        case (_, "Identity"): return g_variant_new_string("Music")
        case (_, "DesktopEntry"): return g_variant_new_string(Desktop.applicationID)
        case (_, "SupportedUriSchemes"), (_, "SupportedMimeTypes"): return Self.strings([])
        case (_, "PlaybackStatus"): return playbackStatus()
        case (_, "Rate"): return g_variant_new_double(state.speed)
        case (_, "MinimumRate"): return g_variant_new_double(Double(PlaybackController.speedRange.lowerBound))
        case (_, "MaximumRate"): return g_variant_new_double(Double(PlaybackController.speedRange.upperBound))
        case (_, "Metadata"): return metadata()
        case (_, "Volume"): return g_variant_new_double(1)
        case (_, "Position"): return g_variant_new_int64(gint64(Self.position(state, at: .now) * 1_000_000))
        case (_, "CanGoNext"): return g_variant_new_boolean(canGoNext ? 1 : 0)
        case (_, "CanGoPrevious"), (_, "CanPlay"), (_, "CanPause"), (_, "CanSeek"), (_, "CanControl"):
            return g_variant_new_boolean(state.song == nil && name != "CanControl" ? 0 : 1)
        default: return nil
        }
    }

    private func call(_ method: String, _ parameters: OpaquePointer?) {
        switch method {
        case "Raise": Desktop.raise()
        case "Quit":
            if let application = Desktop.application { g_application_quit(application.cast()) }
        case "Play": onPlay?()
        case "Pause", "Stop": onPause?()
        case "PlayPause": onToggle?()
        case "Next": onNext?()
        case "Previous": onPrevious?()
        case "Seek":
            guard let parameters else { return }
            let offset = Double(g_variant_get_int64(g_variant_get_child_value(parameters, 0))) / 1_000_000
            onSeek?(max(0, Self.position(state, at: .now) + offset))
        case "SetPosition":
            guard let parameters else { return }
            let path = String(cString: g_variant_get_string(g_variant_get_child_value(parameters, 0), nil))
            let position = Double(g_variant_get_int64(g_variant_get_child_value(parameters, 1))) / 1_000_000
            guard path == Self.trackPath(state.song?.id), position >= 0 else { return }
            onSeek?(position)
        default:
            break
        }
    }

    // MARK: - D-Bus

    private func register(on connection: OpaquePointer) {
        self.connection = connection
        var error: UnsafeMutablePointer<GError>?
        guard let node = g_dbus_node_info_new_for_xml(Self.introspection, &error) else {
            if let error { g_error_free(error) }
            return
        }
        defer { g_dbus_node_info_unref(node) }

        var table = GDBusInterfaceVTable()
        table.method_call = { _, _, _, _, method, parameters, invocation, data in
            guard let data, let method else { return }
            let center = Unmanaged<NowPlayingCenter>.fromOpaque(data).takeUnretainedValue()
            let name = String(cString: method)
            nonisolated(unsafe) let parameters = parameters
            MainActor.assumeIsolated { center.call(name, parameters) }
            g_dbus_method_invocation_return_value(invocation, nil)
        }
        table.get_property = { _, _, _, interface, property, _, data in
            guard let data, let interface, let property else { return nil }
            let center = Unmanaged<NowPlayingCenter>.fromOpaque(data).takeUnretainedValue()
            let interfaceName = String(cString: interface)
            let name = String(cString: property)
            return MainActor.assumeIsolated { Unchecked(center.property(interfaceName, name)) }.value
        }
        // Volume, Rate and the rest are accepted and ignored: the phone's lock screen has
        // no such controls either, and a client that writes one must not get an error.
        table.set_property = { _, _, _, _, _, _, _, _ in 1 }

        let data = Unmanaged.passUnretained(self).toOpaque()
        for name in ["org.mpris.MediaPlayer2", "org.mpris.MediaPlayer2.Player"] {
            guard let interface = g_dbus_node_info_lookup_interface(node, name) else { continue }
            g_dbus_connection_register_object(connection, Self.objectPath, interface, &table, data, nil, nil)
        }
    }

    private func emitChanged(_ properties: [String: OpaquePointer]) {
        guard let connection, !properties.isEmpty else {
            // Floating references nobody took: sink and drop them.
            for value in properties.values { g_variant_unref(g_variant_ref_sink(value)) }
            return
        }
        var children: [OpaquePointer?] = [
            g_variant_new_string("org.mpris.MediaPlayer2.Player"),
            Self.dictionary(properties.map { ($0.key, $0.value) }),
            Self.strings([]),
        ]
        let parameters = g_variant_new_tuple(&children, gsize(children.count))
        g_dbus_connection_emit_signal(
            connection, nil, Self.objectPath,
            "org.freedesktop.DBus.Properties", "PropertiesChanged",
            parameters, nil
        )
    }

    private func emitSeeked(_ seconds: Double) {
        guard let connection else { return }
        var children: [OpaquePointer?] = [g_variant_new_int64(gint64(seconds * 1_000_000))]
        g_dbus_connection_emit_signal(
            connection, nil, Self.objectPath,
            "org.mpris.MediaPlayer2.Player", "Seeked",
            g_variant_new_tuple(&children, 1), nil
        )
    }

    private static let introspection = """
    <node>
      <interface name="org.mpris.MediaPlayer2">
        <method name="Raise"/>
        <method name="Quit"/>
        <property name="CanQuit" type="b" access="read"/>
        <property name="CanRaise" type="b" access="read"/>
        <property name="HasTrackList" type="b" access="read"/>
        <property name="Identity" type="s" access="read"/>
        <property name="DesktopEntry" type="s" access="read"/>
        <property name="SupportedUriSchemes" type="as" access="read"/>
        <property name="SupportedMimeTypes" type="as" access="read"/>
      </interface>
      <interface name="org.mpris.MediaPlayer2.Player">
        <method name="Next"/>
        <method name="Previous"/>
        <method name="Pause"/>
        <method name="PlayPause"/>
        <method name="Stop"/>
        <method name="Play"/>
        <method name="Seek"><arg direction="in" name="Offset" type="x"/></method>
        <method name="SetPosition">
          <arg direction="in" name="TrackId" type="o"/>
          <arg direction="in" name="Position" type="x"/>
        </method>
        <method name="OpenUri"><arg direction="in" name="Uri" type="s"/></method>
        <signal name="Seeked"><arg name="Position" type="x"/></signal>
        <property name="PlaybackStatus" type="s" access="read"/>
        <property name="Rate" type="d" access="readwrite"/>
        <property name="Metadata" type="a{sv}" access="read"/>
        <property name="Volume" type="d" access="readwrite"/>
        <property name="Position" type="x" access="read"/>
        <property name="MinimumRate" type="d" access="read"/>
        <property name="MaximumRate" type="d" access="read"/>
        <property name="CanGoNext" type="b" access="read"/>
        <property name="CanGoPrevious" type="b" access="read"/>
        <property name="CanPlay" type="b" access="read"/>
        <property name="CanPause" type="b" access="read"/>
        <property name="CanSeek" type="b" access="read"/>
        <property name="CanControl" type="b" access="read"/>
      </interface>
    </node>
    """
}
