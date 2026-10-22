import Foundation

/// Remote players: the phone driving the desktop app across the room, the way one
/// Plexamp drives another.
///
/// The desktop is the player. It runs a small HTTP server on the LAN and advertises it;
/// the phone finds it, pairs once, and from then on sends it commands and follows what
/// it plays. Nothing goes through Navidrome: both apps are signed in to the same server,
/// so a song sent from the phone is one the desktop can already stream by its id.
///
/// **Discovery.** DNS-SD over mDNS, type `_music-remote._tcp`, the computer's name as the
/// instance name, and TXT `id=<uuid>` (one per installation, so a renamed or readdressed
/// desktop is still the one that was paired) and `v=1`. Port 47823 when it is free, any
/// port otherwise. A desktop can also be added by address, for networks mDNS does not
/// cross. `GET /v1/info` answers anyone on the LAN with that same `RemoteInfo`.
///
/// **LAN only.** The server answers peers on loopback, private (RFC 1918) and link-local
/// addresses, and closes anything else unanswered.
///
/// **Pairing.** Everything but `/v1/info` and pairing itself needs
/// `Authorization: Bearer <token>`, and a token comes only from pairing:
///
/// 1. `POST /v1/pair/request` `{"device": "iPhone"}` → 202. The desktop shows a six-digit
///    code, in its window and as a notification.
/// 2. `POST /v1/pair/confirm` `{"device": "iPhone", "code": "123456"}` → 200 `RemotePairing.Grant`,
///    or 403. A code lasts two minutes and five wrong tries, and a new request replaces it.
///
/// The desktop keeps one token per paired device until it is forgotten on either side:
/// in its settings, or by the phone with `DELETE /v1/pair`. A request with a token it
/// does not know is 401, which is the phone's cue to pair again.
///
/// **Commands.** `POST /v1/command` with one `RemoteCommand` → 204. Flat JSON, so a
/// terminal can send one: `{"action": "seek", "seconds": 42}`. Queue indices are places in
/// the desktop's play order, which `RemoteMirror` translates from the phone's window.
///
/// **State.** `GET /v1/events` is a server-sent event stream. `hello` comes once, then the
/// `queue` window and the `state`, and after that `queue` whenever the list or its window
/// moves and `state` whenever something a player screen shows changes. Never on a timer:
/// `elapsed` goes with the moment it was read and the phone extrapolates, as a lock screen
/// does, so a `state` is sent for a seek, a stall or a drift past a second, not every
/// second. A `: ping` comment every 15 seconds keeps the connection honest; after 40
/// silent seconds the phone reconnects. Each event is exactly one `event:` line and one
/// `data:` line of JSON, and is acted on at its `data:` line, because the phone's line
/// reader drops the blank line that ends an event.
///
/// HTTP and server-sent events rather than a socket protocol of its own: URLSession
/// streams them on the phone, curl drives them from a terminal, and the desktop's server
/// stays a page of code.
enum RemoteControl {
    static let serviceType = "_music-remote._tcp"
    static let defaultPort: UInt16 = 47823
    static let protocolVersion = 1

    /// How long the stream may stay silent before the phone gives up on it. The desktop
    /// pings every 15 seconds.
    static let silence: TimeInterval = 40
    static let pingInterval: TimeInterval = 15
}

/// What a desktop says about itself, before any pairing: `GET /v1/info`, and the TXT
/// record's `id`.
struct RemoteInfo: Codable, Equatable, Sendable {
    /// Stable for the installation.
    var id: String
    var name: String
    var version: Int = RemoteControl.protocolVersion
}

enum RemotePairing {
    struct Request: Codable, Equatable, Sendable {
        var device: String
    }

    struct Confirm: Codable, Equatable, Sendable {
        var device: String
        var code: String
    }

    struct Grant: Codable, Equatable, Sendable {
        var token: String
        var id: String
        var name: String
    }
}

/// Sent once at the start of the event stream.
struct RemoteHello: Codable, Equatable, Sendable {
    var id: String
    var name: String
    /// The Navidrome server the desktop plays from. The phone warns when it is not its own,
    /// since its songs' ids would mean nothing there.
    var server: String?
}

/// One thing for the player to do. Which fields mean anything depends on `action`.
struct RemoteCommand: Codable, Equatable, Sendable {
    enum Action: String, Codable, Sendable {
        case play, pause, toggle, next, previous
        /// To `seconds`.
        case seek
        /// By `seconds`, either way.
        case skip
        /// To `value`, 0.5...2.
        case speed
        /// To `value`, 0...1.
        case volume
        case startOver
        /// `songs`, from `index`, called `source`; `shuffled`, `seconds` into the first,
        /// `station`; `paused` to load without playing, as a queue picked up from another
        /// device is.
        case playSongs
        case playNext, addToUpNext, append
        /// To `index`.
        case jump
        /// The track at `index`.
        case remove
        /// From `index` to `to`.
        case move
        case clearQueue
        /// Until the queue is `shuffled`.
        case shuffle
        /// Until the queue repeats `repeatMode`.
        case `repeat`
    }

    var action: Action
    var seconds: Double?
    var value: Double?
    var index: Int?
    var to: Int?
    var songs: [Song]?
    var source: String?
    var shuffled: Bool?
    var paused: Bool?
    var repeatMode: RepeatMode?
    var station: Station?

    init(_ action: Action) {
        self.action = action
    }

    static func seek(to seconds: Double) -> RemoteCommand {
        var command = RemoteCommand(.seek)
        command.seconds = seconds
        return command
    }

    static func skip(by seconds: Double) -> RemoteCommand {
        var command = RemoteCommand(.skip)
        command.seconds = seconds
        return command
    }

    static func speed(_ value: Float) -> RemoteCommand {
        var command = RemoteCommand(.speed)
        command.value = Double(value)
        return command
    }

    static func volume(_ value: Double) -> RemoteCommand {
        var command = RemoteCommand(.volume)
        command.value = value
        return command
    }

    static func playSongs(
        _ songs: [Song],
        from index: Int,
        source: String,
        shuffled: Bool = false,
        startAt seconds: Double = 0,
        station: Station? = nil,
        paused: Bool = false
    ) -> RemoteCommand {
        var command = RemoteCommand(.playSongs)
        command.songs = songs
        command.index = index
        command.source = source
        command.shuffled = shuffled ? true : nil
        command.seconds = seconds > 0 ? seconds : nil
        command.station = station
        command.paused = paused ? true : nil
        return command
    }

    static func songs(_ action: Action, _ songs: [Song]) -> RemoteCommand {
        var command = RemoteCommand(action)
        command.songs = songs
        return command
    }

    static func at(_ action: Action, _ index: Int, to destination: Int? = nil) -> RemoteCommand {
        var command = RemoteCommand(action)
        command.index = index
        command.to = destination
        return command
    }

    static func shuffle(_ on: Bool) -> RemoteCommand {
        var command = RemoteCommand(.shuffle)
        command.shuffled = on
        return command
    }

    static func `repeat`(_ mode: RepeatMode) -> RemoteCommand {
        var command = RemoteCommand(.repeat)
        command.repeatMode = mode
        return command
    }
}

/// What a player screen shows, as of the moment it was read.
struct RemoteState: Codable, Equatable, Sendable {
    var song: Song?
    var isPlaying = false
    var isBuffering = false
    /// Seconds into `song` when this was read.
    var elapsed: Double = 0
    var duration: Double = 0
    var speed: Double = 1
    /// 0...1, the desktop's own volume for the app.
    var volume: Double = 1
    /// Place of `song` in the play order.
    var position = 0
    var repeatMode: RepeatMode = .off
    var canAddToUpNext = false

    /// Where playback has got to, `interval` seconds after this was read.
    func elapsed(after interval: TimeInterval) -> Double {
        guard isPlaying, !isBuffering else { return elapsed }
        let moved = elapsed + max(0, interval) * speed
        return duration > 0 ? min(moved, duration) : moved
    }

    /// Whether `self`, read `interval` seconds after `previous`, says anything a listener
    /// of `previous` could not have worked out: any change but the time, or a time more
    /// than a second from where extrapolating `previous` puts it.
    func differs(from previous: RemoteState, after interval: TimeInterval) -> Bool {
        var timeless = self
        timeless.elapsed = previous.elapsed
        guard timeless == previous else { return true }
        return abs(previous.elapsed(after: interval) - elapsed) > 1
    }
}

/// A stretch of the play order around the current track, with its songs.
///
/// A window rather than the queue, because the queue can be a smart playlist of the whole
/// library, 28,000 songs that would be megabytes on every change. The window moves in
/// steps, so a long queue is re-sent every fifty tracks rather than every track.
struct RemoteQueue: Codable, Equatable, Sendable {
    /// Place in the play order of `songs[0]`.
    var offset: Int
    /// The whole queue's length.
    var count: Int
    var songs: [Song]
    var source: String
    var isShuffled: Bool
    var station: Station?

    static let behind = 25
    static let step = 50
    static let size = 300

    /// The range of the play order a window around `position` covers.
    static func range(around position: Int, count: Int) -> Range<Int> {
        let start = min(max(0, position - behind) / step * step, max(0, count - size))
        return start..<min(count, start + size)
    }

    init(offset: Int, count: Int, songs: [Song], source: String, isShuffled: Bool, station: Station? = nil) {
        self.offset = offset
        self.count = count
        self.songs = songs
        self.source = source
        self.isShuffled = isShuffled
        self.station = station
    }

    init(_ queue: PlaybackQueue) {
        let range = Self.range(around: queue.position, count: queue.order.count)
        self.init(
            offset: range.lowerBound,
            count: queue.order.count,
            songs: queue.order[range].compactMap { queue.tracks.indices.contains($0) ? queue.tracks[$0] : nil },
            source: queue.sourceDescription,
            isShuffled: queue.isShuffled,
            station: queue.station
        )
    }
}

/// The phone's picture of a remote player: the last window and state it sent, the queue
/// the phone's player screens show for it, and where its time has got to since.
///
/// The phone's queue is the window, numbered from zero; `translate` turns a command's
/// places in it back into places in the desktop's play order.
struct RemoteMirror: Sendable {
    private(set) var window: RemoteQueue?
    private(set) var state = RemoteState()
    private(set) var stateReceivedAt = Date.distantPast
    private(set) var queue = PlaybackQueue()

    mutating func apply(_ window: RemoteQueue) {
        self.window = window
        queue = PlaybackQueue(
            tracks: window.songs,
            order: Array(window.songs.indices),
            position: localPosition(state.position, in: window),
            repeatMode: state.repeatMode,
            isShuffled: window.isShuffled,
            sourceDescription: window.source,
            station: window.station
        )
    }

    mutating func apply(_ state: RemoteState, at time: Date) {
        self.state = state
        stateReceivedAt = time
        // Position and repeat leave the queue's `listID` alone, so the queue view keeps
        // its rows.
        if let window {
            let position = localPosition(state.position, in: window)
            if queue.position != position { queue.position = position }
        }
        if queue.repeatMode != state.repeatMode { queue.repeatMode = state.repeatMode }
    }

    func elapsed(at time: Date) -> Double {
        state.elapsed(after: time.timeIntervalSince(stateReceivedAt))
    }

    /// Shows a command's effect before the desktop confirms it, where waiting would show
    /// the old value for a moment: a seek would snap the slider back, a volume slider
    /// would fight the finger.
    mutating func anticipate(_ command: RemoteCommand, at time: Date) {
        switch command.action {
        case .seek:
            guard let seconds = command.seconds else { return }
            state.elapsed = seconds
            stateReceivedAt = time
        case .volume:
            guard let value = command.value else { return }
            state.volume = value
        default:
            break
        }
    }

    /// `command` with its places in the phone's window turned into places in the
    /// desktop's play order.
    func translate(_ command: RemoteCommand) -> RemoteCommand {
        let offset = window?.offset ?? 0
        var command = command
        switch command.action {
        case .jump, .remove, .move:
            command.index = command.index.map { $0 + offset }
            command.to = command.to.map { $0 + offset }
        default:
            break
        }
        return command
    }

    private func localPosition(_ position: Int, in window: RemoteQueue) -> Int {
        min(max(0, position - window.offset), max(0, window.songs.count - 1))
    }
}

/// The other end of a remote player, as `PlaybackController` sees it: something that
/// takes commands. What it plays comes back through `PlaybackController.mirror`.
@MainActor
protocol RemotePlayerLink: AnyObject {
    func send(_ command: RemoteCommand)
}

/// Server-sent events, as this protocol uses them: one `event:` and one `data:` line each.
enum EventStream {
    struct Event: Equatable, Sendable {
        var name: String
        var data: String
    }

    /// One event, ready to write. `data` must be a single line, which `JSONEncoder` output
    /// is unless asked to pretty-print.
    static func frame(_ name: String, _ data: String) -> String {
        "event: \(name)\ndata: \(data)\n\n"
    }

    static let ping = ": ping\n\n"

    /// Reads a stream a line at a time.
    struct Parser {
        private var name: String?

        /// The event this line completes, if it does. Blank lines, comments and fields
        /// this protocol does not use are skipped.
        mutating func feed(_ line: some StringProtocol) -> Event? {
            var line = Substring(line)
            if line.hasSuffix("\r") { line = line.dropLast() }
            if line.hasPrefix("event:") {
                name = Self.value(line.dropFirst(6))
                return nil
            }
            guard line.hasPrefix("data:") else { return nil }
            defer { name = nil }
            return Event(name: name ?? "message", data: Self.value(line.dropFirst(5)))
        }

        private static func value(_ field: Substring) -> String {
            String(field.hasPrefix(" ") ? field.dropFirst() : field)
        }
    }
}
