import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#endif

/// What announces this player on the network: Avahi on the desktop, Bonjour on the phone.
protocol RemoteAdvertising: AnyObject, Sendable {
    func publish(name: String, type: String, port: UInt16, txt: [String])
    func withdraw()
}

/// The played-to half of remote players: another device's commands played here, and what
/// plays here told to it. The desktop's from the start; the phone's too, so the desktop
/// can play to it. The protocol is `RemoteControl`'s, in the shared core.
///
/// Every command is a call the desktop's own screens make, on the same
/// `PlaybackController`, so a phone playing an album does exactly what a click on it
/// would -- Sweet Fades, Autoplay, the recently played shelf and all.
@MainActor
@Observable
final class RemoteControlServer {
    static let shared = RemoteControlServer()

    /// A phone that may control this computer.
    struct Device: Codable, Equatable, Identifiable, Sendable {
        var id: UUID
        var name: String
        var token: String
        var pairedAt: Date
        var lastSeenAt: Date?
        /// The device's own id as a player (`RemoteInfo.id`), when it is one too: the
        /// token it was given for a handoff's way back. Nil for a pairing older than that.
        var peerID: String?
    }

    /// A pairing waiting for its code.
    struct Pairing: Equatable {
        var device: String
        var code: String
        var expiresAt: Date
        var triesLeft = 5
    }

    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Keys.enabled)
            isEnabled ? listen() : stopListening()
        }
    }

    /// What phones see this computer called.
    var name: String {
        didSet {
            guard name != oldValue else { return }
            UserDefaults.standard.set(name, forKey: Keys.name)
            advertise()
        }
    }

    private(set) var devices: [Device] = []
    private(set) var pairing: Pairing?
    /// The port being listened on, while listening.
    private(set) var port: UInt16?
    /// How many phones are following along right now.
    private(set) var listenerCount = 0

    /// Shows a new pairing's code, and takes it away again when it is nil.
    @ObservationIgnored var onPairing: (@MainActor (Pairing?) -> Void)?
    /// The devices this one plays to, which a device pairing here becomes one of, so
    /// either can hand playback to the other.
    @ObservationIgnored weak var players: RemotePlayers?
    /// Someone paired by scanning the code: for the window to say so.
    @ObservationIgnored var onPaired: (@MainActor (String) -> Void)?
    /// The key in the QR code now on show, good for ten minutes (`PairingLink`).
    @ObservationIgnored private var linkKey: (key: String, expiresAt: Date)?

    @ObservationIgnored private let id: String
    @ObservationIgnored private weak var app: AppState?
    @ObservationIgnored private var server: HTTPServer?
    @ObservationIgnored private var advertiser: (any RemoteAdvertising)?
    @ObservationIgnored private var streams: [ObjectIdentifier: HTTPConnection] = [:]
    /// Paired devices following what plays here for a handoff (`/v1/now/events`).
    @ObservationIgnored private var watchers: [ObjectIdentifier: HTTPConnection] = [:]
    @ObservationIgnored private var observer: ChangeTracker?
    /// The app's own volume, 0...1, as the other device's slider sets it: the sound
    /// server's stream on the desktop (set in `MusicApplication`). The phone's volume is
    /// the system's, set by its buttons, so there it says full and leaves it.
    @ObservationIgnored var volume: (read: @MainActor () -> Double, write: @MainActor (Double) -> Void) = ({ 1 }, { _ in })
    @ObservationIgnored private var pinger: Task<Void, Never>?
    /// What only the iPhone app can serve a car (`RemoteCarProvider`); nil on the desktop.
    @ObservationIgnored var carProvider: (any RemoteCarProvider)?
    /// Cars following the spectrum, and what feeds them while any do.
    @ObservationIgnored private var spectrumStreams: [ObjectIdentifier: HTTPConnection] = [:]
    @ObservationIgnored private var spectrumFeed: Task<Void, Never>?
    @ObservationIgnored private var expiry: Task<Void, Never>?
    /// What the phones were last told, to say only what they could not work out.
    @ObservationIgnored private var sentState: (state: RemoteState, at: Date)?
    @ObservationIgnored private var sentWindow: (list: UUID, range: Range<Int>)?
    @ObservationIgnored private var sentNow: (now: RemoteNow, at: Date)?

    private enum Keys {
        static let enabled = "remote.enabled"
        static let name = "remote.name"
        static let id = "remote.id"
    }

    private init() {
        let defaults = UserDefaults.standard
        // On by default everywhere: a computer taking over from the phone has to ask it
        // where it has got to and tell it to stop (`Handoff`). The phone listens only while
        // Music is open or playing, and only to devices on its own network or tailnet.
        isEnabled = defaults.object(forKey: Keys.enabled) as? Bool ?? true
        name = defaults.string(forKey: Keys.name) ?? Self.hostName
        if let id = defaults.string(forKey: Keys.id) {
            self.id = id
        } else {
            id = UUID().uuidString
            defaults.set(id, forKey: Keys.id)
        }
        devices = Keychain.loadRemoteDevices()
    }

    /// This installation's id as a player: `RemoteInfo.id`.
    var serverID: String { id }

    /// Who this device is and where it listens, with the token `peerID` is to use: what a
    /// pairing or an introduction tells the other device.
    func introduction(for peerID: String, named peerName: String) -> RemotePeer? {
        guard let port else { return nil }
        return RemotePeer(
            id: id,
            name: name,
            port: port,
            addresses: HTTPServer.localAddresses(),
            token: token(for: peerID, named: peerName)
        )
    }

    /// The token `peerID` may use here, made the first time it is asked for.
    private func token(for peerID: String, named peerName: String) -> String {
        if let device = devices.first(where: { $0.peerID == peerID }) { return device.token }
        let device = Device(id: UUID(), name: peerName, token: Self.randomToken(), pairedAt: .now, peerID: peerID)
        devices.append(device)
        Keychain.saveRemoteDevices(devices)
        return device.token
    }

    /// The pairing link for the QR code: scanning it pairs both ways at once. The same key
    /// while one is on show, a new one once it has expired or been used.
    func pairingLink() -> PairingLink? {
        guard isEnabled, let port else { return nil }
        if linkKey == nil || linkKey!.expiresAt < .now {
            linkKey = (Self.randomToken(), .now.addingTimeInterval(600))
        }
        return PairingLink(id: id, name: name, port: port, addresses: HTTPServer.localAddresses(), key: linkKey!.key)
    }

    private static var hostName: String {
        #if canImport(UIKit)
        return UIDevice.current.name
        #else
        let host = ProcessInfo.processInfo.hostName.split(separator: ".").first.map(String.init) ?? ""
        return host.isEmpty || host == "localhost" ? "Desktop" : host
        #endif
    }

    // MARK: - Running

    func start(app: AppState, advertiser: any RemoteAdvertising) {
        self.app = app
        self.advertiser = advertiser
        if isEnabled { listen() }
    }

    /// Back in front on the phone: iOS may have closed the listening socket while the app
    /// was suspended, so it is opened afresh.
    func appBecameActive() {
        guard isEnabled, app != nil else { return }
        stopListening()
        listen()
    }

    private func listen() {
        guard server == nil, app != nil else { return }
        let server = HTTPServer { request, connection in
            RemoteControlServer.shared.handle(request, on: connection)
        }
        guard server.start(port: RemoteControl.defaultPort) else {
            Task { await Diagnostics.shared.record("remote", "could not listen for phones") }
            return
        }
        self.server = server
        port = server.port
        advertise()
    }

    /// The keep-alive, only while some device follows along: with nobody listening it woke
    /// the app every fifteen seconds to say nothing to no one.
    private func startPinging() {
        guard pinger == nil else { return }
        pinger = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(RemoteControl.pingInterval))
                self?.ping()
            }
        }
    }

    private func stopListening() {
        server?.stop()
        server = nil
        port = nil
        advertiser?.withdraw()
        pinger?.cancel()
        pinger = nil
        for connection in streams.values { connection.close() }
        for connection in watchers.values { connection.close() }
        streams = [:]
        watchers = [:]
        listenerCount = 0
        stopFollowing()
        cancelPairing()
    }

    private func advertise() {
        guard let port else { return }
        advertiser?.publish(
            name: name,
            type: RemoteControl.serviceType,
            port: port,
            txt: ["id=\(id)", "v=\(RemoteControl.protocolVersion)"]
        )
    }

    // MARK: - Devices

    func forget(_ device: Device) {
        devices.removeAll { $0.id == device.id }
        Keychain.saveRemoteDevices(devices)
    }

    func cancelPairing() {
        expiry?.cancel()
        guard pairing != nil else { return }
        pairing = nil
        onPairing?(nil)
    }

    private func device(for request: HTTPServer.Request) -> Device? {
        guard let header = request.headers["authorization"], header.hasPrefix("Bearer ") else { return nil }
        let token = Array(header.dropFirst(7).utf8)
        guard let index = devices.firstIndex(where: { Self.equal(Array($0.token.utf8), token) }) else { return nil }
        // Kept for the settings page; written with the next change rather than on every
        // request.
        devices[index].lastSeenAt = .now
        return devices[index]
    }

    /// Compared in full whatever the first difference, so the time taken says nothing.
    private static func equal(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private static func randomToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }.joined()
    }

    // MARK: - Requests

    private func handle(_ request: HTTPServer.Request, on connection: HTTPConnection) {
        switch (request.method, request.path) {
        case ("GET", "/v1/info"):
            connection.respond(200, json: encode(RemoteInfo(id: id, name: name, addresses: HTTPServer.localAddresses())))
        case ("POST", "/v1/peer"):
            guard let device = device(for: request) else { return connection.respond(401) }
            guard let peer = try? JSONDecoder().decode(RemotePeer.self, from: request.body) else {
                return connection.respond(400)
            }
            meet(peer, from: request.peer, device: device.id)
            connection.respond(204)
        case ("GET", "/v1/now"):
            guard device(for: request) != nil else { return connection.respond(401) }
            connection.respond(200, json: encode(now()))
        case ("GET", "/v1/now/events"):
            guard device(for: request) != nil else { return connection.respond(401) }
            watch(on: connection)
        case ("GET", "/v1/queue"):
            guard device(for: request) != nil else { return connection.respond(401) }
            guard let queue = handoffQueue() else { return connection.respond(404) }
            connection.respond(200, json: encode(queue))
        case ("POST", "/v1/release"):
            guard device(for: request) != nil else { return connection.respond(401) }
            let release = try? JSONDecoder().decode(RemoteRelease.self, from: request.body)
            app?.player.release(to: release?.to)
            connection.respond(204)
        case ("POST", "/v1/pair/request"):
            requestPairing(request, on: connection)
        case ("POST", "/v1/pair/confirm"):
            confirmPairing(request, on: connection)
        case ("DELETE", "/v1/pair"):
            guard let device = device(for: request) else { return connection.respond(401) }
            forget(device)
            connection.respond(204)
        case ("GET", "/v1/events"):
            guard device(for: request) != nil else { return connection.respond(401) }
            follow(on: connection)
        case ("POST", "/v1/command"):
            guard device(for: request) != nil else { return connection.respond(401) }
            guard let command = try? JSONDecoder().decode(RemoteCommand.self, from: request.body) else {
                return connection.respond(400)
            }
            connection.respond(perform(command) ? 204 : 409)
        case ("GET", "/v1/clock"):
            guard device(for: request) != nil else { return connection.respond(401) }
            connection.respond(200, json: encode(RemoteClock(uptime: ProcessInfo.processInfo.systemUptime)))
        case ("GET", "/v1/spectrum"):
            guard device(for: request) != nil else { return connection.respond(401) }
            guard carProvider != nil else { return connection.respond(404) }
            followSpectrum(on: connection)
        default:
            if !carRoute(request, on: connection) { connection.respond(404) }
        }
    }

    /// The car's routes with what they ask for in the path (`RemoteControl`, "The car.").
    /// False for a path that isn't one, which is the caller's 404.
    private func carRoute(_ request: HTTPServer.Request, on connection: HTTPConnection) -> Bool {
        let parts = request.path.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
        guard parts.count >= 2, parts[0] == "v1" else { return false }
        let route = parts[1]
        let rest = Array(parts.dropFirst(2))
        switch (request.method, route) {
        case ("POST", "trips"):
            guard device(for: request) != nil else { connection.respond(401); return true }
            guard rest.count == 1, RemoteCarTrips.save(request.body, id: rest[0]) else { connection.respond(400); return true }
            connection.respond(204)
            return true
        case ("GET", "art"), ("GET", "palette"), ("GET", "lyrics"), ("GET", "levels"), ("GET", "browse"):
            break
        default:
            return false
        }
        guard device(for: request) != nil else { connection.respond(401); return true }
        guard let provider = carProvider else { connection.respond(404); return true }
        // Answered when it is ready: the connection stays open after this returns.
        Task { @MainActor in
            switch route {
            case "art":
                guard rest.count == 2, let size = Int(rest[1]), (16...600).contains(size),
                      let pixels = await provider.art(coverArt: rest[0], size: size)
                else { return connection.respond(404) }
                connection.respond(200, body: pixels, contentType: "application/x-rgb24",
                                   headers: ["X-Width": "\(size)", "X-Height": "\(size)"])
            case "palette":
                guard rest.count == 1, let palette = await provider.palette(coverArt: rest[0]) else { return connection.respond(404) }
                connection.respond(200, json: encode(palette))
            case "lyrics":
                guard rest.count == 1, let lyrics = await provider.lyrics(songID: rest[0]) else { return connection.respond(404) }
                connection.respond(200, json: encode(lyrics))
            case "levels":
                guard rest.count == 1, let levels = await provider.levels(songID: rest[0]) else { return connection.respond(404) }
                connection.respond(200, json: encode(RemoteCarLevels(levels: levels)))
            default:
                guard let page = await provider.browse(path: rest.joined(separator: "/")) else { return connection.respond(404) }
                connection.respond(200, json: encode(page))
            }
        }
        return true
    }

    private func requestPairing(_ request: HTTPServer.Request, on connection: HTTPConnection) {
        guard let body = try? JSONDecoder().decode(RemotePairing.Request.self, from: request.body) else {
            return connection.respond(400)
        }
        let device = String(body.device.prefix(60))
        let code = String(format: "%06d", Int.random(in: 0...999_999))
        let pairing = Pairing(device: device.isEmpty ? "A phone" : device, code: code, expiresAt: .now.addingTimeInterval(120))
        self.pairing = pairing
        onPairing?(pairing)
        expiry?.cancel()
        expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(120))
            guard !Task.isCancelled, self?.pairing?.code == code else { return }
            self?.cancelPairing()
        }
        connection.respond(202)
    }

    private func confirmPairing(_ request: HTTPServer.Request, on connection: HTTPConnection) {
        guard let body = try? JSONDecoder().decode(RemotePairing.Confirm.self, from: request.body) else {
            return connection.respond(400)
        }
        // The QR code's key: scanned, so nothing was asked for first and nothing to type.
        if let link = linkKey, link.expiresAt > .now,
           Self.equal(Array(body.code.utf8), Array(link.key.utf8)) {
            linkKey = nil
            let name = String(body.device.prefix(60))
            let device = grant(to: name.isEmpty ? "A phone" : name, peer: body.peer, from: request.peer)
            onPaired?(device.name)
            return connection.respond(200, json: encode(RemotePairing.Grant(token: device.token, id: id, name: self.name)))
        }
        guard var pairing, pairing.expiresAt > .now else {
            return connection.respond(410)
        }
        guard Self.equal(Array(body.code.filter(\.isNumber).utf8), Array(pairing.code.utf8)) else {
            pairing.triesLeft -= 1
            if pairing.triesLeft > 0 {
                self.pairing = pairing
            } else {
                cancelPairing()
            }
            return connection.respond(403)
        }
        let device = grant(to: pairing.device, peer: body.peer, from: request.peer)
        cancelPairing()
        connection.respond(200, json: encode(RemotePairing.Grant(token: device.token, id: id, name: name)))
    }

    /// A new token for a device that has just paired, and, if it plays too, it added to
    /// the devices this one plays to, with the token it gave for the way back.
    private func grant(to name: String, peer: RemotePeer?, from address: String) -> Device {
        // Pairing again replaces the old token rather than leaving it to pile up.
        if let peer { devices.removeAll { $0.peerID == peer.id } }
        let device = Device(id: UUID(), name: name, token: Self.randomToken(), pairedAt: .now, peerID: peer?.id)
        devices.append(device)
        Keychain.saveRemoteDevices(devices)
        if let peer { players?.met(peer, at: address) }
        return device
    }

    /// A paired device saying who it is as a player, where, and with what token.
    private func meet(_ peer: RemotePeer, from address: String, device deviceID: UUID) {
        if let index = devices.firstIndex(where: { $0.id == deviceID }), devices[index].peerID != peer.id {
            devices[index].peerID = peer.id
            Keychain.saveRemoteDevices(devices)
        }
        players?.met(peer, at: address)
    }

    // MARK: - Handoff

    /// What plays here, for a device deciding whether to take it over. Nothing while this
    /// device is itself playing to another: its queue is not its own then.
    private func now() -> RemoteNow {
        guard let player = app?.player, player.remote == nil else {
            return RemoteNow(id: id, name: name, listID: "", count: 0, state: RemoteState(), savedAt: nil)
        }
        let queue = player.queue
        return RemoteNow(
            id: id,
            name: name,
            listID: queue.isEmpty ? "" : queue.listID.uuidString,
            count: queue.order.count,
            state: currentState(player),
            savedAt: player.lastSavedAt
        )
    }

    private func handoffQueue() -> RemoteHandoffQueue? {
        guard let player = app?.player, player.remote == nil, !player.queue.isEmpty else { return nil }
        let queue = player.queue
        var songs: [Song] = []
        var position = 0
        for (place, index) in queue.order.enumerated() where queue.tracks.indices.contains(index) {
            if place == queue.position { position = songs.count }
            songs.append(queue.tracks[index])
        }
        return RemoteHandoffQueue(
            listID: queue.listID.uuidString,
            songs: songs,
            position: position,
            source: queue.sourceDescription,
            station: queue.station,
            repeatMode: queue.repeatMode
        )
    }

    private func currentState(_ player: PlaybackController) -> RemoteState {
        RemoteState(
            song: player.currentSong,
            isPlaying: player.isPlaying,
            isBuffering: player.isBuffering,
            elapsed: player.elapsedNow,
            duration: player.duration,
            speed: Double(player.speed),
            volume: volume.read(),
            position: player.queue.position,
            repeatMode: player.queue.repeatMode,
            canAddToUpNext: player.canAddToUpNext
        )
    }

    // MARK: - Commands

    /// False for a command that cannot apply: a place no longer in the queue.
    private func perform(_ command: RemoteCommand) -> Bool {
        guard let player = app?.player else { return false }
        let count = player.queue.order.count
        func valid(_ index: Int?) -> Int? {
            guard let index, (0..<count).contains(index) else { return nil }
            return index
        }

        // Another device's own commands: played here as they are, never taken for a press
        // of play here, which would look for a device to take the music from.
        switch command.action {
        case .play: player.play(handingOff: false)
        case .pause: player.pause()
        case .toggle: player.isPlaying ? player.pause() : player.play(handingOff: false)
        case .next: player.next()
        case .previous: player.previous()
        case .seek:
            guard let seconds = command.seconds else { return false }
            player.seek(to: max(0, seconds))
        case .skip:
            guard let seconds = command.seconds else { return false }
            player.skip(by: seconds)
        case .speed:
            guard let value = command.value else { return false }
            player.setSpeed(Float(value))
        case .volume:
            guard let value = command.value else { return false }
            volume.write(min(max(value, 0), 1))
        case .startOver:
            player.startOver()
        case .playSongs:
            guard let songs = command.songs, !songs.isEmpty else { return false }
            let index = min(max(command.index ?? 0, 0), songs.count - 1)
            let source = command.source ?? "Queue"
            if command.paused == true {
                player.adopt(songs: songs, currentID: songs[index].id, positionSeconds: command.seconds ?? 0, source: source)
            } else {
                player.play(
                    songs: songs,
                    startingAt: index,
                    source: source,
                    shuffled: command.shuffled ?? false,
                    startAt: command.seconds ?? 0,
                    station: command.station
                )
            }
        case .playNext:
            guard let songs = command.songs else { return false }
            player.playNext(songs)
        case .addToUpNext:
            guard let songs = command.songs else { return false }
            player.addToUpNext(songs)
        case .append:
            guard let songs = command.songs else { return false }
            player.append(songs)
        case .jump:
            guard let index = valid(command.index) else { return false }
            player.jump(toOrderIndex: index)
        case .remove:
            guard let index = valid(command.index) else { return false }
            player.removeFromQueue(orderIndex: index)
        case .move:
            guard let index = valid(command.index), let destination = command.to, destination >= 0 else { return false }
            // `count` is the end: the destination is counted before the row is lifted out.
            player.moveInQueue(from: index, to: min(destination, count))
        case .clearQueue:
            player.clearQueue()
        case .shuffle:
            guard let on = command.shuffled else { return false }
            if player.queue.isShuffled != on { player.toggleShuffle() }
        case .repeat:
            guard let mode = command.repeatMode else { return false }
            for _ in RepeatMode.allCases where player.queue.repeatMode != mode {
                player.cycleRepeat()
            }
        case .playItem:
            guard let provider = carProvider, let kind = command.kind, let id = command.id else { return false }
            let index = command.index ?? 0
            let shuffled = command.shuffled ?? false
            Task { _ = await provider.playItem(kind: kind, id: id, index: index, shuffled: shuffled) }
        }
        return true
    }

    // MARK: - Following

    private func follow(on connection: HTTPConnection) {
        let key = ObjectIdentifier(connection)
        connection.onClose = {
            Task { @MainActor in RemoteControlServer.shared.drop(key) }
        }
        streams[key] = connection
        listenerCount = streams.count
        connection.startEvents()
        connection.send(EventStream.frame("hello", json(RemoteHello(
            id: id, name: name, server: app?.credentials?.baseURL.absoluteString
        ))))
        // Everyone is told the whole picture again, which a newcomer needs and the others
        // can take; it keeps one record of what was last said.
        sentWindow = nil
        sentState = nil
        track()
    }

    /// A paired device following what plays here (`Handoff`): told `now` at once, and
    /// again only when it has news.
    private func watch(on connection: HTTPConnection) {
        let key = ObjectIdentifier(connection)
        connection.onClose = {
            Task { @MainActor in RemoteControlServer.shared.drop(key) }
        }
        watchers[key] = connection
        connection.startEvents()
        sentNow = nil
        track()
    }

    /// Follows the player afresh, so that whatever a newcomer is told is read, and so
    /// watched, from now on.
    private func track() {
        startPinging()
        observer?.cancel()
        observer = ChangeTracker { [weak self] in self?.publish() }
    }

    private func drop(_ key: ObjectIdentifier) {
        streams[key] = nil
        watchers[key] = nil
        listenerCount = streams.count
        if streams.isEmpty, watchers.isEmpty {
            stopFollowing()
            pinger?.cancel()
            pinger = nil
        }
    }

    private func stopFollowing() {
        observer?.cancel()
        observer = nil
        sentState = nil
        sentWindow = nil
        sentNow = nil
    }

    /// Runs whenever anything it reads changes, which while playing is the elapsed time,
    /// four times a second; says something only when that is news.
    private func publish() {
        guard let player = app?.player else { return }
        if !watchers.isEmpty { publishNow() }
        guard !streams.isEmpty else { return }
        let queue = player.queue
        let range = RemoteQueue.range(around: queue.position, count: queue.order.count)
        if sentWindow?.list != queue.listID || sentWindow?.range != range {
            sentWindow = (queue.listID, range)
            broadcast(EventStream.frame("queue", json(RemoteQueue(queue))))
        }

        let state = RemoteState(
            song: player.currentSong,
            isPlaying: player.isPlaying,
            isBuffering: player.isBuffering,
            elapsed: player.elapsed,
            duration: player.duration,
            speed: Double(player.speed),
            volume: volume.read(),
            position: queue.position,
            repeatMode: queue.repeatMode,
            canAddToUpNext: player.canAddToUpNext
        )
        let now = Date.now
        if let sent = sentState, !state.differs(from: sent.state, after: now.timeIntervalSince(sent.at)) { return }
        sentState = (state, now)
        broadcast(EventStream.frame("state", json(timed(state, player))))
    }

    /// `state` as sent, with the car's timing: the song position leaving the speakers now
    /// (`RemoteState.mediaTime`). Kept off the copy compared, since it changes every instant.
    private func timed(_ state: RemoteState, _ player: PlaybackController) -> RemoteState {
        var state = state
        let latency = carProvider?.outputLatency ?? 0
        state.mediaTime = max(0, player.elapsedNow - latency)
        state.atUptime = ProcessInfo.processInfo.systemUptime
        state.rate = player.isPlaying && !player.isBuffering ? Double(player.speed) : 0
        state.outputLatency = latency
        return state
    }

    // MARK: - The car's spectrum

    /// A car following the spectrum: `spectrum` events, each with the song position of its
    /// samples, and with what is heard when, so the car's timing never drifts from the
    /// music's. Fed only while one listens; a ping when there is nothing new, so a paused
    /// song doesn't read as a dropped connection.
    private func followSpectrum(on connection: HTTPConnection) {
        let key = ObjectIdentifier(connection)
        connection.onClose = {
            Task { @MainActor in RemoteControlServer.shared.dropSpectrum(key) }
        }
        spectrumStreams[key] = connection
        connection.startEvents()
        guard spectrumFeed == nil else { return }
        spectrumFeed = Task { @MainActor [weak self] in
            var last = -1.0
            var quietSince = Date.now
            while !Task.isCancelled {
                try? await Task.sleep(for: RemoteCarSpectrum.interval)
                guard let self, !self.spectrumStreams.isEmpty else { return }
                var event: String?
                if let frame = self.carProvider?.spectrum(), frame.mediaTime != last, let player = self.app?.player {
                    last = frame.mediaTime
                    let latency = self.carProvider?.outputLatency ?? 0
                    let rate = player.isPlaying && !player.isBuffering ? Double(player.speed) : 0
                    event = RemoteCarSpectrum.event(
                        mediaTime: frame.mediaTime, bands: frame.bands,
                        heard: max(0, player.elapsedNow - latency), at: ProcessInfo.processInfo.systemUptime, rate: rate
                    )
                    quietSince = .now
                } else if Date.now.timeIntervalSince(quietSince) > 5 {
                    event = EventStream.ping
                    quietSince = .now
                }
                guard let event else { continue }
                for connection in self.spectrumStreams.values { connection.send(event) }
            }
        }
    }

    private func dropSpectrum(_ key: ObjectIdentifier) {
        spectrumStreams[key] = nil
        guard spectrumStreams.isEmpty else { return }
        spectrumFeed?.cancel()
        spectrumFeed = nil
    }

    /// What plays here, to the devices following it, when it is news: closer than the
    /// remote's second, since the lyrics there are lit word by word from it.
    private func publishNow() {
        guard let player = app?.player else { return }
        let now = now()
        let at = Date.now
        // Following another device itself, its time is that one's, which the follower can
        // hear from there: only what changes here is news.
        let tolerance = !player.isPlaying && player.isTimeMoving ? Double.infinity : 0.3
        if let sent = sentNow, sent.now.listID == now.listID, sent.now.count == now.count,
           sent.now.name == now.name,
           !now.state.differs(from: sent.now.state, after: at.timeIntervalSince(sent.at), by: tolerance) {
            return
        }
        sentNow = (now, at)
        let frame = EventStream.frame("now", json(now))
        for connection in watchers.values { connection.send(frame) }
    }

    private func broadcast(_ text: String) {
        for connection in streams.values { connection.send(text) }
    }

    private func ping() {
        for connection in streams.values { connection.send(EventStream.ping) }
        for connection in watchers.values { connection.send(EventStream.ping) }
    }

    // MARK: - Encoding

    private func encode(_ value: some Encodable) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data("{}".utf8)
    }

    private func json(_ value: some Encodable) -> String {
        String(decoding: encode(value), as: UTF8.self)
    }
}

/// Runs `body` now, and again each time anything it read changes: the server following
/// the player. Observation's own tracking, so it is the same on the phone and the
/// desktop, whose UI has an `Observer` of its own.
@MainActor
private final class ChangeTracker {
    private var body: (@MainActor () -> Void)?

    init(_ body: @escaping @MainActor () -> Void) {
        self.body = body
        run()
    }

    func cancel() {
        body = nil
    }

    private func run() {
        guard let body else { return }
        withObservationTracking {
            body()
        } onChange: { [weak self] in
            Task { @MainActor in self?.run() }
        }
    }
}

