import Foundation
import Network

/// The phone's way of finding computers: Bonjour through Network, each one's address
/// found by connecting to it. See `RemotePlayers`.
@MainActor
final class NetworkRemoteBrowser: RemoteBrowsing {
    private var browser: NWBrowser?
    private var sightings: [String: RemoteSighting] = [:]
    private var report: (@MainActor ([RemoteSighting]) -> Void)?

    func start(_ found: @escaping @MainActor ([RemoteSighting]) -> Void) {
        guard browser == nil else { return }
        report = found
        sightings = [:]
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: RemoteControl.serviceType, domain: nil),
            using: .tcp
        )
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            // Delivered on the main queue, which `start` was given.
            MainActor.assumeIsolated { self?.found(results) }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
        report = nil
    }

    private func found(_ results: Set<NWBrowser.Result>) {
        var seen: [String: RemoteSighting] = [:]
        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint,
                  case let .bonjour(txt) = result.metadata,
                  let id = txt["id"]
            else { continue }
            var sighting = sightings[id] ?? RemoteSighting(id: id, name: name)
            sighting.name = name
            seen[id] = sighting
            let endpoint = result.endpoint
            Task { await resolve(endpoint, id: id) }
        }
        sightings = seen
        report?(Array(seen.values))
    }

    /// Where a computer is now, looked up each time it is seen.
    private func resolve(_ endpoint: NWEndpoint, id: String) async {
        guard let address = await Self.address(of: endpoint), var sighting = sightings[id],
              sighting.host != address.host || sighting.port != address.port
        else { return }
        sighting.host = address.host
        sighting.port = address.port
        sightings[id] = sighting
        report?(Array(sightings.values))
    }

    /// A service's IPv4 address and port, found by connecting to it: the one way Network
    /// offers. IPv4 because a link-local IPv6 address needs its interface in the URL.
    private nonisolated static func address(of endpoint: NWEndpoint) async -> (host: String, port: UInt16)? {
        await withCheckedContinuation { continuation in
            let parameters = NWParameters.tcp
            if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
                ip.version = .v4
            }
            let connection = NWConnection(to: endpoint, using: parameters)
            let once = ResumeOnce(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    var address: (host: String, port: UInt16)?
                    if case let .hostPort(host, port)? = connection.currentPath?.remoteEndpoint,
                       case let .ipv4(ipv4) = host {
                        address = (ipv4.rawValue.map(String.init).joined(separator: "."), port.rawValue)
                    }
                    once.resume(address)
                    connection.cancel()
                case .failed, .waiting:
                    once.resume(nil)
                    connection.cancel()
                case .cancelled:
                    once.resume(nil)
                    // The handler holds the connection; let it go.
                    connection.stateUpdateHandler = nil
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                once.resume(nil)
                connection.cancel()
            }
        }
    }
}

/// Resumes a continuation once, whichever of a connection's states and a timeout comes
/// first.
private final class ResumeOnce<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Value) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }
}
