import Network
import Observation

/// Whether there is any network at all.
///
/// Deliberately not "can we reach Navidrome": the server is on a home LAN, so a
/// reachability probe would be a request that fails slowly on cellular and succeeds
/// only at home. The useful signal is the interface state, which `NWPathMonitor`
/// gives instantly, plus the client's short timeout as the real arbiter.
///
/// It exists mainly to drive one behaviour that matters: flushing the scrobble outbox
/// the moment the phone gets a network back.
@MainActor
@Observable
final class Reachability {
    private(set) var isOnline = true
    /// True on cellular or a personal hotspot.
    private(set) var isExpensive = false
    /// Low Data Mode. Treated as cellular: it is the user saying "this one costs".
    private(set) var isConstrained = false

    /// What streaming quality and cache-ahead go by.
    var network: NetworkKind {
        guard isOnline else { return .offline }
        return isExpensive || isConstrained ? .cellular : .wifi
    }

    private let monitor = NWPathMonitor()
    /// Fired on every transition *into* online, which is the interesting edge.
    var onCameOnline: (() -> Void)?
    /// Fired whenever `network` changes — Wi-Fi to cellular, online to off.
    var onNetworkChange: (() -> Void)?

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let expensive = path.isExpensive
            let constrained = path.isConstrained

            Task { @MainActor in
                guard let self else { return }
                let wasOnline = self.isOnline
                let previous = self.network
                self.isOnline = online
                self.isExpensive = expensive
                self.isConstrained = constrained
                if online, !wasOnline { self.onCameOnline?() }
                if self.network != previous { self.onNetworkChange?() }
            }
        }
        monitor.start(queue: .global(qos: .utility))
    }

    deinit {
        monitor.cancel()
    }
}
