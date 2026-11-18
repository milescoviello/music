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
        /// Every address it has said it listens at, its tailnet's among them: where to look
        /// when `host` no longer answers, on another network or after a new lease.
        var addresses: [String]?

        var isPaired: Bool { token != nil }

        var baseURL: URL? {
            guard let host, let port else { return nil }
            return URL(string: "http://\(host):\(port)")
        }

        /// Where to try, the last address that answered first.
        var candidates: [URL] {
            guard let port else { return [] }
            var hosts: [String] = []
            for host in [host].compactMap({ $0 }) + (addresses ?? []) where !hosts.contains(host) {
                hosts.append(host)
            }
            return hosts.compactMap { URL(string: "http://\($0):\(port)") }
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
    /// A pairing made from a scanned code, or why it failed: said over whatever is open.
    var notice: String?
    /// What moves playback between this device and the paired ones.
    let handoff: Handoff

    private let appState: AppState
    private let requests: URLSession
    @ObservationIgnored private let browser: any RemoteBrowsing
    @ObservationIgnored private var isBrowsing = false
    /// Computers told this run who this device is (`introduce`): once each is enough.
    @ObservationIgnored private var introduced: Set<String> = []
    /// Short-lived requests for a handoff, which must not keep a press of play waiting.
    @ObservationIgnored private let quick: URLSession

    init(appState: AppState, browser: any RemoteBrowsing) {
        self.appState = appState
        self.browser = browser
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        #if !canImport(FoundationNetworking)
        configuration.waitsForConnectivity = false
        #endif
        requests = URLSession(configuration: configuration)
        let quickConfiguration = URLSessionConfiguration.ephemeral
        quickConfiguration.timeoutIntervalForRequest = 2
        #if !canImport(FoundationNetworking)
        quickConfiguration.waitsForConnectivity = false
        #endif
        quick = URLSession(configuration: quickConfiguration)
        handoff = Handoff(app: appState)
        if let data = Keychain.loadRemotePlayers(),
           let paired = try? JSONDecoder().decode([Computer].self, from: data) {
            computers = paired
        }
        handoff.players = self
        appState.handoff = handoff
        RemoteControlServer.shared.players = self
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
            // This device as a player too, with a token for the way back: pairing once lets
            // either end take the music from the other.
            let peer = RemoteControlServer.shared.introduction(for: computer.id, named: computer.name)
            let (data, status) = try await post(
                base.appendingPathComponent("v1/pair/confirm"),
                RemotePairing.Confirm(device: Self.deviceName, code: code, peer: peer)
            )
            switch status {
            case 200:
                let grant = try JSONDecoder().decode(RemotePairing.Grant.self, from: data)
                guard let index = computers.firstIndex(where: { $0.id == computer.id }) else { return }
                computers[index].token = grant.token
                computers[index].name = grant.name
                save()
                if peer != nil { introduced.insert(computer.id) }
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

    // MARK: - Pairing by QR code

    /// Pairs from a scanned `music-remote://pair` link: the desktop's Remote Control page
    /// shows it as a QR code, and the camera opens it here. Both ways at once, and without
    /// playing to the computer afterwards: it is for handing off, not for a remote.
    func pair(link url: URL) async {
        guard let link = PairingLink(url) else {
            notice = "That code isn't a Music pairing code."
            return
        }
        let server = RemoteControlServer.shared
        if !server.isEnabled { server.isEnabled = true }
        let peer = server.introduction(for: link.id, named: link.name)
        var computer = computers.first { $0.id == link.id }
            ?? Computer(id: link.id, name: link.name, host: nil, port: link.port)
        computer.port = link.port
        computer.addresses = link.addresses

        for base in computer.candidates {
            guard let (data, status) = try? await post(
                base.appendingPathComponent("v1/pair/confirm"),
                RemotePairing.Confirm(device: Self.deviceName, code: link.key, peer: peer)
            ) else { continue }
            guard status == 200, let grant = try? JSONDecoder().decode(RemotePairing.Grant.self, from: data) else {
                notice = status == 403 || status == 410
                    ? "That code has expired. Open Remote Control on \(link.name) again for a new one."
                    : "\(link.name) answered, but wouldn't pair."
                return
            }
            computer.token = grant.token
            computer.name = grant.name
            computer.host = base.host
            if let index = computers.firstIndex(where: { $0.id == computer.id }) {
                computers[index] = computer
            } else {
                computers.append(computer)
            }
            introduced.insert(computer.id)
            save()
            notice = "Paired with \(grant.name). Press play on either one to carry on from the other."
            return
        }
        notice = "Couldn't reach \(link.name). Is this iPhone on the same network, or on Tailscale?"
    }

    // MARK: - Reaching paired devices

    /// A paired device introduced itself (`RemotePeer`): kept, or brought up to date, as one
    /// this device can take the music from and play to.
    func met(_ peer: RemotePeer, at address: String) {
        var addresses = [address]
        for other in peer.addresses where !addresses.contains(other) { addresses.append(other) }
        if let index = computers.firstIndex(where: { $0.id == peer.id }) {
            computers[index].name = peer.name
            computers[index].token = peer.token
            computers[index].host = address
            computers[index].port = peer.port
            computers[index].addresses = addresses
        } else {
            computers.append(Computer(id: peer.id, name: peer.name, host: address, port: peer.port, token: peer.token, addresses: addresses))
        }
        save()
    }

    /// The paired devices, not counting this one should it see itself on the network.
    var paired: [Computer] {
        computers.filter { $0.isPaired && $0.id != RemoteControlServer.shared.serverID }
    }

    /// A paired device's `GET` answer, from the first of its addresses to answer, with the
    /// round trip it took. The address that answered becomes the one tried first.
    func ask<Answer: Decodable>(
        _ computer: Computer,
        _ path: String,
        as type: Answer.Type,
        within timeout: TimeInterval
    ) async -> (answer: Answer, base: URL, roundTrip: TimeInterval, at: Date)? {
        guard let token = computer.token else { return nil }
        let candidates = computer.candidates
        guard !candidates.isEmpty else { return nil }
        let found = await Self.firstAnswer(from: candidates, path: path, token: token, timeout: timeout, session: quick)
        guard let (data, base, roundTrip, at) = found else { return nil }
        if roundTrip < 0 {
            // It has forgotten this device: its token is no use any more.
            if let index = computers.firstIndex(where: { $0.id == computer.id }) {
                computers[index].token = nil
                save()
            }
            return nil
        }
        guard let answer = try? JSONDecoder().decode(Answer.self, from: data) else { return nil }
        noteAnswered(computer, at: base)
        return (answer, base, roundTrip, at)
    }

    /// Every address at once; the first good answer wins (`Race`).
    private nonisolated static func firstAnswer(
        from candidates: [URL],
        path: String,
        token: String,
        timeout: TimeInterval,
        session: URLSession
    ) async -> (Data, URL, TimeInterval, Date)? {
        let jobs: [@Sendable () async -> (Data, URL, TimeInterval, Date)?] = candidates.map { base in
            {
                var request = URLRequest(url: base.appendingPathComponent(path))
                request.timeoutInterval = timeout
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                let sent = Date.now
                guard let (data, response) = try? await session.data(for: request),
                      let status = (response as? HTTPURLResponse)?.statusCode
                else { return nil }
                // Refused: a roundTrip below zero says so.
                if status == 401 { return (Data(), base, -1, .now) }
                guard status == 200 else { return nil }
                let received = Date.now
                return (data, base, received.timeIntervalSince(sent), received)
            }
        }
        return await Race.first(of: jobs, within: timeout + 0.3)
    }

    /// Tells a paired device to pause because the music has moved here.
    func release(_ computer: Computer, at base: URL) async {
        guard let token = computer.token else { return }
        var request = URLRequest(url: base.appendingPathComponent("v1/release"))
        request.httpMethod = "POST"
        request.timeoutInterval = 3
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONEncoder().encode(RemoteRelease(to: RemoteControlServer.shared.name))
        _ = try? await quick.data(for: request)
    }

    private func noteAnswered(_ computer: Computer, at base: URL) {
        guard let index = computers.firstIndex(where: { $0.id == computer.id }) else { return }
        if let host = base.host, computers[index].host != host {
            computers[index].host = host
            save()
        }
        introduce(computers[index], at: base)
    }

    /// Tells a paired device who this one is as a player, where it listens now, and the
    /// token to use: so it can take the music from here too, and find this device on
    /// whatever network it is on. Once a run; a pairing from before this existed gets its
    /// way back the first time it is reached.
    private func introduce(_ computer: Computer, at base: URL) {
        guard !introduced.contains(computer.id), let token = computer.token,
              let peer = RemoteControlServer.shared.introduction(for: computer.id, named: computer.name)
        else { return }
        introduced.insert(computer.id)
        let requests = requests
        Task {
            var request = URLRequest(url: base.appendingPathComponent("v1/peer"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.httpBody = try? JSONEncoder().encode(peer)
            _ = try? await requests.data(for: request)
        }
    }

    /// Looks on the local network for a few seconds, when some paired device did not
    /// answer at any address it is known by: Bonjour may know its new one.
    func lookAround() {
        guard !isBrowsing else { return }
        startBrowsing()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            self?.stopBrowsing()
        }
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
