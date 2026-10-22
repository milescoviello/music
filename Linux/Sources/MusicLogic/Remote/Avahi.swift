import CGtk
import Foundation

/// Advertises the remote on the LAN through Avahi, over the system bus.
///
/// D-Bus rather than libavahi-client: GIO already speaks it, so this is no new library to
/// build against or to install, and a desktop without Avahi running just goes unannounced
/// -- the phone can still add it by address. Avahi drops the entry by itself when the app's
/// bus connection closes, so quitting needs nothing.
///
/// The calls block, for at most a few seconds when Avahi is wedged, so they run on a
/// thread of their own.
final class Avahi: @unchecked Sendable {
    private let lock = NSLock()
    private var bus: OpaquePointer?
    private var group: String?

    /// Replaces whatever was advertised before.
    func publish(name: String, type: String, port: UInt16, txt: [String]) {
        let thread = Thread { [self] in
            lock.lock()
            defer { lock.unlock() }
            resetLocked()
            guard let bus = connectLocked() else { return }
            guard let reply = call(bus, "/", "org.freedesktop.Avahi.Server", "EntryGroupNew", nil, reply: "(o)") else { return }
            let path = String(cString: g_variant_get_string(g_variant_get_child_value(reply, 0), nil))
            g_variant_unref(reply)
            group = path

            // A name already taken on this network gets a number, as Avahi's own tools do.
            for candidate in [name, "\(name) (2)", "\(name) (3)"] {
                let added = call(bus, path, "org.freedesktop.Avahi.EntryGroup", "AddService", Self.service(
                    name: candidate, type: type, port: port, txt: txt
                ))
                guard let added else { continue }
                g_variant_unref(added)
                if let committed = call(bus, path, "org.freedesktop.Avahi.EntryGroup", "Commit", nil) {
                    g_variant_unref(committed)
                }
                return
            }
        }
        thread.name = "remote-avahi"
        thread.start()
    }

    func withdraw() {
        let thread = Thread { [self] in
            lock.lock()
            defer { lock.unlock() }
            resetLocked()
        }
        thread.start()
    }

    private func resetLocked() {
        guard let bus, let path = group else { return }
        group = nil
        if let reply = call(bus, path, "org.freedesktop.Avahi.EntryGroup", "Free", nil) { g_variant_unref(reply) }
    }

    private func connectLocked() -> OpaquePointer? {
        if let bus { return bus }
        var error: UnsafeMutablePointer<GError>?
        bus = g_bus_get_sync(G_BUS_TYPE_SYSTEM, nil, &error)
        if let error {
            report(error)
            return nil
        }
        return bus
    }

    private func call(
        _ bus: OpaquePointer,
        _ path: String,
        _ interface: String,
        _ method: String,
        _ parameters: OpaquePointer?,
        reply: String? = nil
    ) -> OpaquePointer? {
        var error: UnsafeMutablePointer<GError>?
        // A type of its own, not `cgtk_variant_type`: that casts the C string Swift makes
        // for a `String`, which is gone by the time GDBus reads it.
        let type = reply.flatMap { g_variant_type_new($0) }
        defer { if let type { g_variant_type_free(type) } }
        let result = g_dbus_connection_call_sync(
            bus, "org.freedesktop.Avahi", path, interface, method, parameters,
            type, GDBusCallFlags(rawValue: 0), 5000, nil, &error
        )
        if let error { report(error) }
        return result
    }

    private func report(_ error: UnsafeMutablePointer<GError>) {
        let message = String(cString: error.pointee.message)
        g_error_free(error)
        Task { await Diagnostics.shared.record("remote", "Avahi: \(message)") }
    }

    /// `AddService`'s arguments: `(iiussssqaay)`, on every interface and protocol.
    private static func service(name: String, type: String, port: UInt16, txt: [String]) -> OpaquePointer {
        var records = txt.map { entry -> OpaquePointer? in
            let bytes = Array(entry.utf8)
            return bytes.withUnsafeBufferPointer {
                g_variant_new_fixed_array(cgtk_variant_type("y"), $0.baseAddress, gsize($0.count), 1)
            }
        }
        var children: [OpaquePointer?] = [
            g_variant_new_int32(-1),
            g_variant_new_int32(-1),
            g_variant_new_uint32(0),
            g_variant_new_string(name),
            g_variant_new_string(type),
            g_variant_new_string(""),
            g_variant_new_string(""),
            g_variant_new_uint16(port),
            g_variant_new_array(cgtk_variant_type("ay"), &records, gsize(records.count)),
        ]
        return g_variant_new_tuple(&children, gsize(children.count))
    }
}
