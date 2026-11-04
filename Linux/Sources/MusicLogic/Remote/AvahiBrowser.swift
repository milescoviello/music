import CGtk
import Foundation

/// Finds the computers running Music on this network, for Play On: Avahi's service
/// browser over the system bus, as `Avahi` publishes this one. Each one found is resolved
/// to an IPv4 address, port and TXT record; its `id` tells a computer seen twice, and this
/// computer itself, which is left out.
///
/// Signals arrive on the main loop, where the subscription was made; resolving blocks,
/// for at most a few seconds, so it runs on a thread of its own.
@MainActor
final class AvahiBrowser: RemoteBrowsing {
    private var bus: OpaquePointer?
    private var subscriptions: [guint] = []
    private var browserPath: String?
    /// By Avahi's name for the service, which is what a removal says.
    private var sightings: [String: RemoteSighting] = [:]
    private var report: (@MainActor ([RemoteSighting]) -> Void)?

    private static let browserInterface = "org.freedesktop.Avahi.ServiceBrowser"

    func start(_ found: @escaping @MainActor ([RemoteSighting]) -> Void) {
        guard bus == nil else { return }
        report = found
        sightings = [:]
        var error: UnsafeMutablePointer<GError>?
        guard let bus = g_bus_get_sync(G_BUS_TYPE_SYSTEM, nil, &error) else {
            if let error { g_error_free(error) }
            return
        }
        self.bus = bus
        let data = Unmanaged.passUnretained(self).toOpaque()
        // Subscribed before the browser exists, so nothing it says first is missed.
        for signal in ["ItemNew", "ItemRemove"] {
            let id = g_dbus_connection_signal_subscribe(
                bus, "org.freedesktop.Avahi", Self.browserInterface, signal, nil, nil,
                GDBusSignalFlags(rawValue: 0),
                { _, _, path, _, signal, parameters, data in
                    guard let data, let path, let signal, let parameters else { return }
                    let browser = Unmanaged<AvahiBrowser>.fromOpaque(data).takeUnretainedValue()
                    let fields = AvahiBrowser.item(parameters)
                    let pathName = String(cString: path), signalName = String(cString: signal)
                    MainActor.assumeIsolated { browser.received(signalName, path: pathName, item: fields) }
                },
                data, nil
            )
            subscriptions.append(id)
        }
        var children: [OpaquePointer?] = [
            g_variant_new_int32(-1),
            g_variant_new_int32(0),  // IPv4: a link-local IPv6 address needs its interface in a URL
            g_variant_new_string(RemoteControl.serviceType),
            g_variant_new_string(""),
            g_variant_new_uint32(0),
        ]
        let parameters = g_variant_new_tuple(&children, gsize(children.count))
        let type = g_variant_type_new("(o)")
        defer { g_variant_type_free(type) }
        if let reply = g_dbus_connection_call_sync(
            bus, "org.freedesktop.Avahi", "/", "org.freedesktop.Avahi.Server", "ServiceBrowserNew",
            parameters, type, GDBusCallFlags(rawValue: 0), 5000, nil, &error
        ) {
            browserPath = String(cString: g_variant_get_string(g_variant_get_child_value(reply, 0), nil))
            g_variant_unref(reply)
        } else if let error {
            let message = String(cString: error.pointee.message)
            g_error_free(error)
            Task { await Diagnostics.shared.record("remote", "Avahi browse: \(message)") }
        }
    }

    func stop() {
        guard let bus else { return }
        for id in subscriptions { g_dbus_connection_signal_unsubscribe(bus, id) }
        subscriptions = []
        if let path = browserPath {
            g_dbus_connection_call(
                bus, "org.freedesktop.Avahi", path, Self.browserInterface, "Free",
                nil, nil, GDBusCallFlags(rawValue: 0), 2000, nil, nil, nil
            )
        }
        browserPath = nil
        self.bus = nil
        report = nil
    }

    /// `ItemNew` and `ItemRemove`'s `(iisssu)`: interface, protocol, name, type, domain.
    private nonisolated static func item(_ parameters: OpaquePointer) -> (interface: Int32, proto: Int32, name: String, type: String, domain: String)? {
        guard g_variant_n_children(parameters) >= 5 else { return nil }
        func string(_ index: Int) -> String {
            let child = g_variant_get_child_value(parameters, gsize(index))
            defer { g_variant_unref(child) }
            return String(cString: g_variant_get_string(child, nil))
        }
        func int(_ index: Int) -> Int32 {
            let child = g_variant_get_child_value(parameters, gsize(index))
            defer { g_variant_unref(child) }
            return g_variant_get_int32(child)
        }
        return (int(0), int(1), string(2), string(3), string(4))
    }

    private func received(_ signal: String, path: String, item: (interface: Int32, proto: Int32, name: String, type: String, domain: String)?) {
        guard let item, item.type == RemoteControl.serviceType else { return }
        if let browserPath, path != browserPath { return }
        switch signal {
        case "ItemRemove":
            if sightings.removeValue(forKey: item.name) != nil { report?(Array(sightings.values)) }
        case "ItemNew":
            resolve(item)
        default:
            break
        }
    }

    private func resolve(_ item: (interface: Int32, proto: Int32, name: String, type: String, domain: String)) {
        guard let bus else { return }
        let own = UserDefaults.standard.string(forKey: "remote.id")
        nonisolated(unsafe) let connection = bus
        let thread = Thread { [weak self] in
            guard let found = Self.resolveSync(connection, item), found.id != own else { return }
            Task { @MainActor in
                guard let self, self.report != nil else { return }
                self.sightings[item.name] = found
                self.report?(Array(self.sightings.values))
            }
        }
        thread.name = "remote-resolve"
        thread.start()
    }

    /// `ResolveService`, answered as `(iissssisqaayu)`: the address, port and TXT record.
    private nonisolated static func resolveSync(
        _ bus: OpaquePointer,
        _ item: (interface: Int32, proto: Int32, name: String, type: String, domain: String)
    ) -> RemoteSighting? {
        var children: [OpaquePointer?] = [
            g_variant_new_int32(item.interface),
            g_variant_new_int32(item.proto),
            g_variant_new_string(item.name),
            g_variant_new_string(item.type),
            g_variant_new_string(item.domain),
            g_variant_new_int32(0),
            g_variant_new_uint32(0),
        ]
        let parameters = g_variant_new_tuple(&children, gsize(children.count))
        var error: UnsafeMutablePointer<GError>?
        guard let reply = g_dbus_connection_call_sync(
            bus, "org.freedesktop.Avahi", "/", "org.freedesktop.Avahi.Server", "ResolveService",
            parameters, nil, GDBusCallFlags(rawValue: 0), 5000, nil, &error
        ) else {
            if let error { g_error_free(error) }
            return nil
        }
        defer { g_variant_unref(reply) }
        guard g_variant_n_children(reply) >= 10 else { return nil }
        let addressValue = g_variant_get_child_value(reply, 7)
        let portValue = g_variant_get_child_value(reply, 8)
        let txtValue = g_variant_get_child_value(reply, 9)
        defer {
            g_variant_unref(addressValue)
            g_variant_unref(portValue)
            g_variant_unref(txtValue)
        }
        let address = String(cString: g_variant_get_string(addressValue, nil))
        let port = g_variant_get_uint16(portValue)
        var id: String?
        for index in 0..<g_variant_n_children(txtValue) {
            let entry = g_variant_get_child_value(txtValue, index)
            var length: gsize = 0
            if let bytes = g_variant_get_fixed_array(entry, &length, 1) {
                let text = String(decoding: UnsafeRawBufferPointer(start: bytes, count: Int(length)), as: UTF8.self)
                if text.hasPrefix("id=") { id = String(text.dropFirst(3)) }
            }
            g_variant_unref(entry)
        }
        guard let id else { return nil }
        return RemoteSighting(id: id, name: item.name, host: address, port: port)
    }
}
