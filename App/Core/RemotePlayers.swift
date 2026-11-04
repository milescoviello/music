import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Observation
#if canImport(UIKit)
import UIKit
#endif

/// What finds computers on the network: Bonjour through Network on the phone, Avahi on
/// the desktop. Each sighting as it changes, the whole set each time.
@MainActor
protocol RemoteBrowsing: AnyObject {
    func start(_ found: @escaping @MainActor ([RemoteSighting]) -> Void)
    func stop()
}

/// A computer seen on the network, with where it is once that is known.
struct RemoteSighting: Equatable, Sendable {
    var id: String
    var name: String
    var host: String?
    var port: UInt16?
}

/// Remote players, Plexamp's "play on": the computers on this network running Music, the
/// ones paired, and the one being played to. The phone's, and the desktop's too: one
/// computer can play to another.
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
    @ObservationIgnored private let browser: any RemoteBrowsing
    @ObservationIgnored private var isBrowsing = false

    init(appState: AppState, browser: any RemoteBrowsing) {
        self.appState = appState
        self.browser = browser
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        #if !canImport(FoundationNetworking)
        configuration.waitsForConnectivity = false
        #endif
        requests = URLSession(configuration: configuration)
        if let data = Keychain.loadRemotePlayers(),
           let paired = try? JSONDecoder().decode([Computer].self, from: data) {
            computers = paired
        }
    }

    private static var deviceName: String {
        #if canImport(UIKit)
        UIDevice.current.name
        #else
        ProcessInfo.processInfo.hostName
        #endif
    }

    // MARK: - Finding computers

    /// Looks for computers while the picker is open. The first time, iOS asks whether the
    /// app may use the local network.
    func startBrowsing() {
        guard !isBrowsing else { return }
        isBrowsing = true
        computers.removeAll { !$0.isPaired && $0.id != session?.computer.id }
        nearby = []
        browser.start { [weak self] sightings in self?.found(sightings) }
    }

    func stopBrowsing() {
        browser.stop()
        isBrowsing = false
    }

    private func found(_ sightings: [RemoteSighting]) {
        var changed = false
        for sighting in sightings {
            if let index = computers.firstIndex(where: { $0.id == sighting.id }) {
                // Renamed on the computer since it was paired.
                if computers[index].name != sighting.name { computers[index].name = sighting.name }
                // An address can change with every lease, so it is taken each time it is
                // seen, and remembered for when it is not.
                if let host = sighting.host, let port = sighting.port,
                   computers[index].host != host || computers[index].port != port {
                    computers[index].host = host
                    computers[index].port = port
                    changed = true
                }
            } else {
                computers.append(Computer(id: sighting.id, name: sighting.name, host: sighting.host, port: sighting.port))
            }
        }
        nearby = Set(sightings.map(\.id))
        if changed { save() }
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
            let (data, response) = try await requests.data(for: URLRequest(url: url))
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
            let status = try await post(base.appendingPathComponent("v1/pair/request"), RemotePairing.Request(device: Self.deviceName)).1
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
                base.appendingPathComponent("v1/pair/confirm"),
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
            var request = URLRequest(url: base.appendingPathComponent("v1/pair"))
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
