import Foundation
import Observation

/// The desktop's half of remote players: the phone's commands played here, and what plays
/// here told to the phone. The protocol is `RemoteControl`'s, in the shared core.
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

    @ObservationIgnored private let id: String
    @ObservationIgnored private weak var app: AppState?
    @ObservationIgnored private var server: HTTPServer?
    @ObservationIgnored private let avahi = Avahi()
    @ObservationIgnored private var streams: [ObjectIdentifier: HTTPConnection] = [:]
    @ObservationIgnored private var observer: Observer?
    @ObservationIgnored private var pinger: Task<Void, Never>?
    @ObservationIgnored private var expiry: Task<Void, Never>?
    /// What the phones were last told, to say only what they could not work out.
    @ObservationIgnored private var sentState: (state: RemoteState, at: Date)?
    @ObservationIgnored private var sentWindow: (list: UUID, range: Range<Int>)?

    private enum Keys {
        static let enabled = "remote.enabled"
        static let name = "remote.name"
        static let id = "remote.id"
    }

    private init() {
        let defaults = UserDefaults.standard
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

    private static var hostName: String {
        let host = ProcessInfo.processInfo.hostName.split(separator: ".").first.map(String.init) ?? ""
        return host.isEmpty || host == "localhost" ? "Desktop" : host
    }

    // MARK: - Running

    func start(app: AppState) {
        self.app = app
        if isEnabled { listen() }
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
        pinger = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(RemoteControl.pingInterval))
                self?.broadcast(EventStream.ping)
            }
        }
    }

    private func stopListening() {
        server?.stop()
        server = nil
        port = nil
        avahi.withdraw()
        pinger?.cancel()
        for connection in streams.values { connection.close() }
        streams = [:]
        listenerCount = 0
        stopFollowing()
        cancelPairing()
    }

    private func advertise() {
        guard let port else { return }
        avahi.publish(
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
            connection.respond(200, json: encode(RemoteInfo(id: id, name: name)))
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
        default:
            connection.respond(404)
        }
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
        let device = Device(id: UUID(), name: pairing.device, token: Self.randomToken(), pairedAt: .now)
        devices.append(device)
        Keychain.saveRemoteDevices(devices)
        cancelPairing()
        connection.respond(200, json: encode(RemotePairing.Grant(token: device.token, id: id, name: name)))
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

        switch command.action {
        case .play: player.play()
        case .pause: player.pause()
        case .toggle: player.togglePlayPause()
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
            OutputVolume.shared.level = min(max(value, 0), 1)
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
            player.moveInQueue(from: index, to: min(destination, count - 1))
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
        if observer == nil {
            observer = Observer { [weak self] in self?.publish() }
        } else {
            publish()
        }
    }

    private func drop(_ key: ObjectIdentifier) {
        streams[key] = nil
        listenerCount = streams.count
        if streams.isEmpty { stopFollowing() }
    }

    private func stopFollowing() {
        observer?.cancel()
        observer = nil
        sentState = nil
        sentWindow = nil
    }

    /// Runs whenever anything it reads changes, which while playing is the elapsed time,
    /// four times a second; says something only when that is news.
    private func publish() {
        guard let player = app?.player else { return }
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
            volume: OutputVolume.shared.level,
            position: queue.position,
            repeatMode: queue.repeatMode,
            canAddToUpNext: player.canAddToUpNext
        )
        let now = Date.now
        if let sent = sentState, !state.differs(from: sent.state, after: now.timeIntervalSince(sent.at)) { return }
        sentState = (state, now)
        broadcast(EventStream.frame("state", json(state)))
    }

    private func broadcast(_ text: String) {
        for connection in streams.values { connection.send(text) }
    }

    // MARK: - Encoding

    private func encode(_ value: some Encodable) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data("{}".utf8)
    }

    private func json(_ value: some Encodable) -> String {
        String(decoding: encode(value), as: UTF8.self)
    }
}
