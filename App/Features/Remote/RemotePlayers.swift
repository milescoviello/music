import Foundation
import Network
import Observation
import UIKit

/// The phone's side of remote players, Plexamp's "play on": the computers on this network
/// running Music, the ones paired, and the one being played to.
///
/// Choosing one hands `PlaybackController` a `RemoteSession`, after which every screen
/// that plays or shows music plays and shows it there. The protocol is `RemoteControl`'s.
///
/// The phone starts out playing to itself after every launch, whatever was chosen
/// before: a computer that has been switched off since should not make the app open on
/// an error.
@MainActor
@Observable
final class RemotePlayers {
    /// A computer this phone knows of: seen on the network, paired, or both.
    struct Computer: Codable, Equatable, Identifiable, Sendable {
        var id: String
        var name: String
        var host: String?
        var port: UInt16?
        /// Present once paired.
        var token: String?

        var isPaired: Bool { token != nil }

        var baseURL: URL? {
            guard let host, let port else { return nil }
            return URL(string: "http://\(host):\(port)")
        }
    }

    /// The paired computers, then any others seen on the network.
    private(set) var computers: [Computer] = []
    /// The ids of the computers seen on the network while browsing.
    private(set) var nearby: Set<String> = []
    /// The computer being played to, and its connection.
    private(set) var session: RemoteSession?
    /// The computer whose code is being typed in.
    private(set) var pairing: Computer?
    /// The last thing that went wrong, for the picker to say.
    var problem: String?

    private let appState: AppState
    private let requests: URLSession
    @ObservationIgnored private var browser: NWBrowser?

    init(appState: AppState) {
        self.appState = appState
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.waitsForConnectivity = false
        requests = URLSession(configuration: configuration)
        if let data = Keychain.loadRemotePlayers(),
           let paired = try? JSONDecoder().decode([Computer].self, from: data) {
            computers = paired
        }
    }

    private static var deviceName: String { UIDevice.current.name }

    // MARK: - Finding computers

    /// Looks for computers while the picker is open. The first time, iOS asks whether the
    /// app may use the local network.
    func startBrowsing() {
        guard browser == nil else { return }
        computers.removeAll { !$0.isPaired && $0.id != session?.computer.id }
        nearby = []
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

    func stopBrowsing() {
        browser?.cancel()
        browser = nil
    }

    private func found(_ results: Set<NWBrowser.Result>) {
        var seen: Set<String> = []
        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint,
                  case let .bonjour(txt) = result.metadata,
                  let id = txt["id"]
            else { continue }
            seen.insert(id)
            if let index = computers.firstIndex(where: { $0.id == id }) {
                // Renamed on the computer since it was paired.
                if computers[index].name != name { computers[index].name = name }
            } else {
                computers.append(Computer(id: id, name: name))
            }
            let endpoint = result.endpoint
            Task { await resolve(endpoint, id: id) }
        }
        nearby = seen
    }

    /// Where a computer is now: an address can change with every lease, so it is looked
    /// up again each time it is seen, and remembered for when it is not.
    private func resolve(_ endpoint: NWEndpoint, id: String) async {
        guard let address = await Self.address(of: endpoint),
              let index = computers.firstIndex(where: { $0.id == id }),
              computers[index].host != address.host || computers[index].port != address.port
        else { return }
        computers[index].host = address.host
        computers[index].port = address.port
        save()
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

    /// Adds a computer by the address its Remote Control settings show: `192.168.1.20`, or
    /// with `:port`.
    func add(address text: String) async {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard let host = parts.first.map(String.init), !host.isEmpty,
              let port = parts.count > 1 ? UInt16(parts[1]) : RemoteControl.defaultPort,
              let url = URL(string: "http://\(host):\(port)/v1/info")
        else {
            problem = "That doesn't look like an address."
            return
        }
        do {
            let (data, response) = try await requests.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let info = try JSONDecoder().decode(RemoteInfo.self, from: data)
            if let index = computers.firstIndex(where: { $0.id == info.id }) {
                computers[index].host = host
                computers[index].port = port
                computers[index].name = info.name
            } else {
                computers.append(Computer(id: info.id, name: info.name, host: host, port: port))
            }
            save()
            if let computer = computers.first(where: { $0.id == info.id }), !computer.isPaired {
                await beginPairing(computer)
            }
        } catch {
            // The reason too: "nothing answered" covers iOS refusing the connection itself.
            problem = "Nothing at \(host) answered (\(error.localizedDescription)). Is Music open there, with Remote Control on?"
        }
    }

    // MARK: - Pairing

    /// Asks the computer to show a code.
    func beginPairing(_ computer: Computer) async {
        guard let base = computer.baseURL else {
            problem = "\(computer.name) hasn't been found on this network yet."
            return
        }
        do {
            let status = try await post(base.appending(path: "v1/pair/request"), RemotePairing.Request(device: Self.deviceName)).1
            guard status == 202 else { throw URLError(.badServerResponse) }
            pairing = computer
        } catch {
            problem = "Couldn't reach \(computer.name)."
        }
    }

    func cancelPairing() {
        pairing = nil
    }

    /// Sends the code typed in, and plays to the computer once it is paired.
    func finishPairing(code: String) async {
        guard let computer = pairing, let base = computer.baseURL else { return }
        pairing = nil
        do {
            let (data, status) = try await post(
                base.appending(path: "v1/pair/confirm"),
                RemotePairing.Confirm(device: Self.deviceName, code: code)
            )
            switch status {
            case 200:
                let grant = try JSONDecoder().decode(RemotePairing.Grant.self, from: data)
                guard let index = computers.firstIndex(where: { $0.id == computer.id }) else { return }
                computers[index].token = grant.token
                computers[index].name = grant.name
                save()
                await select(computers[index])
            case 403:
                problem = "That isn't the code \(computer.name) showed. Tap it to get a new one."
            default:
                problem = "The code on \(computer.name) has expired. Tap it to get a new one."
            }
        } catch {
            problem = "Couldn't reach \(computer.name)."
        }
    }

    /// Forgets a computer here and, if it can be reached, there too.
    func forget(_ computer: Computer) async {
        if session?.computer.id == computer.id { await playHere(moving: false) }
        if let base = computer.baseURL, let token = computer.token {
            var request = URLRequest(url: base.appending(path: "v1/pair"))
            request.httpMethod = "DELETE"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            _ = try? await requests.data(for: request)
        }
        if nearby.contains(computer.id), let index = computers.firstIndex(where: { $0.id == computer.id }) {
            computers[index].token = nil
        } else {
            computers.removeAll { $0.id == computer.id }
        }
        save()
    }

    /// The computer stopped accepting this phone's token: forgotten there.
    private func lostPairing(_ computer: Computer) {
        if let index = computers.firstIndex(where: { $0.id == computer.id }) {
            computers[index].token = nil
            save()
        }
        problem = "\(computer.name) has forgotten this iPhone. Tap it to pair again."
        Task { await playHere(moving: false) }
    }

    // MARK: - Choosing where to play

    /// Plays to `computer` from now on, pairing first if need be. With `moving`, what is
    /// playing here goes with it, at the same place in the same track.
    func select(_ computer: Computer, moving: Bool = false) async {
        guard session?.computer.id != computer.id else { return }
        guard computer.isPaired, let base = computer.baseURL, let token = computer.token else {
            await beginPairing(computer)
            return
        }
        let player = appState.player
        // Read before `control`, which empties the player's queue.
        let handover = moving ? Self.handover(from: player) : nil
        session?.stop()

        let session = RemoteSession(computer: computer, base: base, token: token, player: player)
        session.onUnauthorized = { [weak self] in self?.lostPairing(computer) }
        self.session = session
        player.control(session)
        session.start()
        if let handover { session.send(handover) }
    }

    /// Plays on this phone again. With `moving`, what the computer was playing comes
    /// here -- the part of its queue the phone was shown -- and the computer pauses.
    func playHere(moving: Bool) async {
        guard let session else { return }
        let mirror = session.mirror
        if moving { session.send(RemoteCommand(.pause)) }
        await session.finishSending()
        session.stop()
        self.session = nil
        await appState.player.controlLocally()

        let queue = mirror.queue
        guard moving, !queue.isEmpty else { return }
        appState.player.play(
            songs: queue.order.map { queue.tracks[$0] },
            startingAt: queue.position,
            source: queue.sourceDescription.isEmpty ? "Queue" : queue.sourceDescription,
            startAt: mirror.elapsed(at: .now),
            station: queue.station
        )
    }

    /// The queue playing here, as one command to start it there.
    private static func handover(from player: PlaybackController) -> RemoteCommand? {
        let queue = player.queue
        guard !queue.isEmpty else { return nil }
        let songs = queue.order.compactMap { queue.tracks.indices.contains($0) ? queue.tracks[$0] : nil }
        return .playSongs(
            songs,
            from: queue.position,
            source: queue.sourceDescription.isEmpty ? "Queue" : queue.sourceDescription,
            startAt: player.elapsed,
            station: queue.station
        )
    }

    /// The app came back to the foreground, where the stream is worth opening again now
    /// rather than waiting out its silence or its back-off.
    func appBecameActive() {
        session?.reconnect()
    }

    /// Whether the computer being played to plays from a different server than this phone:
    /// its songs' ids would mean nothing there.
    var playsFromAnotherServer: Bool {
        guard let server = session?.hello?.server, let ours = appState.credentials?.baseURL.absoluteString else {
            return false
        }
        func trimmed(_ address: String) -> String { address.hasSuffix("/") ? String(address.dropLast()) : address }
        return trimmed(server) != trimmed(ours)
    }

    // MARK: - Plumbing

    private func post(_ url: URL, _ body: some Encodable) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await requests.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// Only paired computers are kept; the rest are found again by browsing.
    private func save() {
        let paired = computers.filter(\.isPaired)
        guard let data = try? JSONEncoder().encode(paired) else { return }
        Keychain.saveRemotePlayers(data)
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
