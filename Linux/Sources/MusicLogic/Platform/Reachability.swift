import CGtk
import Observation

/// Whether there is any network at all, from GIO's network monitor.
///
/// The phone's version distinguishes Wi-Fi from cellular because one of them costs. A
/// desktop has no cellular radio, but it can be on a metered connection — a phone's
/// hotspot, a capped mobile broadband stick — and NetworkManager says so. Metered is
/// treated as cellular for exactly the reason Low Data Mode is on the phone: it is the
/// user saying "this one costs", and streaming quality and cache-ahead should listen.
@MainActor
@Observable
final class Reachability {
    private(set) var isOnline = true
    /// True on a connection NetworkManager reports as metered.
    private(set) var isExpensive = false
    /// Kept for the shared code's sake; GIO has no separate low-data flag.
    private(set) var isConstrained = false

    /// What streaming quality and cache-ahead go by.
    var network: NetworkKind {
        guard isOnline else { return .offline }
        return isExpensive || isConstrained ? .cellular : .wifi
    }

    /// Fired on every transition *into* online, which is the interesting edge.
    @ObservationIgnored var onCameOnline: (() -> Void)?
    /// Fired whenever `network` changes — unmetered to metered, online to off.
    @ObservationIgnored var onNetworkChange: (() -> Void)?

    @ObservationIgnored private let monitor: OpaquePointer?

    init() {
        monitor = g_network_monitor_get_default()
        guard let monitor else { return }
        read()
        Signal.connect(monitor, "network-changed", bool: { [weak self] _ in self?.update() })
        Signal.connect(monitor, "notify::network-metered", pointer: { [weak self] _ in self?.update() })
    }

    private func read() {
        guard let monitor else { return }
        isOnline = g_network_monitor_get_network_available(monitor) != 0
        isExpensive = g_network_monitor_get_network_metered(monitor) != 0
    }

    private func update() {
        let wasOnline = isOnline
        let previous = network
        read()
        if isOnline, !wasOnline { onCameOnline?() }
        if network != previous { onNetworkChange?() }
    }
}
