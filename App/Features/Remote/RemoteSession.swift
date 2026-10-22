import Foundation
import Observation

/// One computer being played to: its event stream followed into the player, and the
/// player's commands sent to it, in order.
///
/// The stream is retried for as long as the computer is chosen, sooner at first and every
/// ten seconds after that, so a computer that sleeps or drops off Wi-Fi comes back by
/// itself. Between events the elapsed time is moved on here, four times a second, the
/// way the phone's own output ticks.
@MainActor
@Observable
final class RemoteSession: RemotePlayerLink {
    enum Status: Equatable {
        case connecting, connected, reconnecting, unreachable
    }

    let computer: RemotePlayers.Computer
    private(set) var status = Status.connecting
    private(set) var hello: RemoteHello?
    /// What the computer last said, and what the player shows of it.
    private(set) var mirror = RemoteMirror()

    /// The computer refused the token: it has forgotten this phone.
    @ObservationIgnored var onUnauthorized: (@MainActor () -> Void)?

    @ObservationIgnored private let base: URL
    @ObservationIgnored private let token: String
    @ObservationIgnored private weak var player: PlaybackController?
    @ObservationIgnored private let connection: URLSession
    @ObservationIgnored private var stream: Task<Void, Never>?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    /// The last command sent; each waits for the one before, so a seek and a play arrive
    /// in the order they were made.
    @ObservationIgnored private var sending: Task<Void, Never>?
    @ObservationIgnored private var pendingVolume: Double?
    @ObservationIgnored private var sendsVolume = false

    init(computer: RemotePlayers.Computer, base: URL, token: String, player: PlaybackController) {
        self.computer = computer
        self.base = base
        self.token = token
        self.player = player
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = RemoteControl.silence
        configuration.waitsForConnectivity = false
        connection = URLSession(configuration: configuration)
    }

    /// 0...1, the computer's own volume for the app.
    var volume: Double { mirror.state.volume }

    // MARK: - Following

    func start() {
        stream?.cancel()
        stream = Task { [weak self] in await self?.follow() }
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self else { return }
                if mirror.state.isPlaying { player?.mirror(mirror) }
            }
        }
    }

    func stop() {
        stream?.cancel()
        ticker?.cancel()
        stream = nil
        ticker = nil
        connection.invalidateAndCancel()
    }

    /// Opens the stream again now. Coming back from the background, a stream can still
    /// look connected though iOS let it die while the app was suspended; a new one is
    /// told the whole picture at once.
    func reconnect() {
        guard stream != nil else { return }
        start()
    }

    private func follow() async {
        var failures = 0
        while !Task.isCancelled {
            do {
                var request = URLRequest(url: base.appending(path: "v1/events"))
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                request.timeoutInterval = RemoteControl.silence
                let (bytes, response) = try await connection.bytes(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                if code == 401 {
                    onUnauthorized?()
                    return
                }
                guard code == 200 else { throw URLError(.badServerResponse) }
                var parser = EventStream.Parser()
                for try await line in bytes.lines {
                    guard let event = parser.feed(line) else { continue }
                    if status != .connected {
                        status = .connected
                        failures = 0
                    }
                    receive(event)
                }
            } catch {
                if Task.isCancelled { return }
            }
            failures += 1
            status = failures >= 3 ? .unreachable : .reconnecting
            try? await Task.sleep(for: .seconds(min(Double(failures) * 2, 10)))
        }
    }

    private func receive(_ event: EventStream.Event) {
        let data = Data(event.data.utf8)
        let decoder = JSONDecoder()
        switch event.name {
        case "hello":
            hello = try? decoder.decode(RemoteHello.self, from: data)
            return
        case "queue":
            guard let window = try? decoder.decode(RemoteQueue.self, from: data) else { return }
            mirror.apply(window)
        case "state":
            guard let state = try? decoder.decode(RemoteState.self, from: data) else { return }
            mirror.apply(state, at: .now)
        default:
            return
        }
        player?.mirror(mirror)
    }

    // MARK: - Commands

    func send(_ command: RemoteCommand) {
        let translated = mirror.translate(command)
        mirror.anticipate(command, at: .now)
        player?.mirror(mirror)
        let previous = sending
        sending = Task { [weak self] in
            await previous?.value
            await self?.post(translated)
        }
    }

    /// Volume follows a finger, so only the latest value is sent once the one before it
    /// has gone, rather than every step of the drag.
    func setVolume(_ value: Double) {
        mirror.anticipate(.volume(value), at: .now)
        pendingVolume = value
        guard !sendsVolume else { return }
        sendsVolume = true
        Task { [weak self] in
            while let value = self?.takePendingVolume() {
                await self?.post(.volume(value))
            }
            self?.sendsVolume = false
        }
    }

    private func takePendingVolume() -> Double? {
        defer { pendingVolume = nil }
        return pendingVolume
    }

    /// Waits until every command sent so far has been delivered or has failed.
    func finishSending() async {
        await sending?.value
    }

    private func post(_ command: RemoteCommand) async {
        var request = URLRequest(url: base.appending(path: "v1/command"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(command)
        request.timeoutInterval = 10
        guard let response = try? await connection.data(for: request).1 else { return }
        if (response as? HTTPURLResponse)?.statusCode == 401 { onUnauthorized?() }
    }
}
