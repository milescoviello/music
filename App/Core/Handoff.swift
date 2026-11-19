import Foundation
import Observation

/// Moving the music between this device and the paired ones, with nothing to choose:
/// press play here and it carries on from wherever it was playing, at the same second,
/// and the device it was playing on pauses.
///
/// On a press of play with nothing playing here, every paired device is asked what it is
/// playing (`GET /v1/now`, a few hundred bytes, all at once). Then:
///
/// - **One is playing:** its whole queue is fetched (once; kept for the next time), loaded
///   here paused at where it will have got to, and once the track has opened here it is
///   moved on to where the other device has got to by then and started -- and only when
///   it is sounding is the other told to pause (`POST /v1/release`). The two overlap by a
///   tick rather than leave a gap.
/// - **None is, but one was listened to more recently than this one:** its queue, at the
///   exact place it was paused.
/// - **None answers:** the queue on the server, if another device saved it more recently
///   (`QueueSync`: every pause, and every twenty seconds while playing).
/// - **Otherwise** this device's own queue, as before.
///
/// Its place is reckoned on this device's clock alone, from the round trip -- the other
/// read its time half a round trip before the answer came back -- so neither clock has
/// to be right.
///
/// The same happens, without playing, when the app comes to the front or the desktop's
/// window is focused, so the player already shows what a press of play will play.
///
/// **Following.** While this device is idle -- the phone on screen, the desktop always --
/// it follows the paired device that is playing: the same track, the time moving, on to
/// the next track when that one moves on, the lyrics with it. Asked once a second
/// (`/v1/now`, a few hundred bytes); nothing is fetched to play until play is pressed
/// here. Play is still the one press that brings the music over. Starting anything else
/// here pauses the device being followed: the music moved here.
@MainActor
@Observable
final class Handoff {
    /// Finding out where the music is, and bringing it here.
    private(set) var isMoving = false
    /// The last device the music came from, for the log and the player.
    private(set) var lastMove: (from: String, at: Date)?

    @ObservationIgnored weak var players: RemotePlayers?
    @ObservationIgnored private weak var app: AppState?
    /// The queue last taken from another device, so taking it again -- the same list, a
    /// track or two on -- needs only where that device has got to.
    @ObservationIgnored private var taken: (peerID: String, queue: RemoteHandoffQueue)?
    /// When the server's queue was last looked at.
    @ObservationIgnored private var serverLookedAt: Date?
    /// Paired devices that did not answer the last time, and when: asked again, but not
    /// waited for as long, so a laptop asleep in a bag does not slow down every press.
    @ObservationIgnored private var silentSince: [String: Date] = [:]
    /// Play was pressed while a look was under way.
    @ObservationIgnored private var playWhenDone = false

    /// When a paired device last answered: lately, a press of play asks before playing.
    @ObservationIgnored private var lastAnswerAt: Date?
    /// How long the follower waits between looks for a device to follow.
    @ObservationIgnored private var searchWait: TimeInterval = 3

    /// The device being followed, by name, while this one is idle.
    private(set) var following: String?
    @ObservationIgnored private var followed: (computer: RemotePlayers.Computer, base: URL)?
    /// What it last said, and when it read it by this device's clock.
    @ObservationIgnored private var followedState: (state: RemoteState, readAt: Date)?
    /// This device's queue as it was made from the followed one, to know it still is.
    @ObservationIgnored private var followedList: UUID?
    @ObservationIgnored private var followFailures = 0
    @ObservationIgnored private var follower: Task<Void, Never>?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    /// On screen. The phone follows only then; the desktop has no such thing.
    #if canImport(UIKit)
    @ObservationIgnored private var isActive = false
    #else
    @ObservationIgnored private var isActive = true
    #endif

    /// How long ahead of the other device's place to start, for the moment this one's
    /// output takes to start sounding once told to play.
    static let startLead: Double = 0.15

    init(app: AppState) {
        self.app = app
    }

    // MARK: - Entry points

    /// Play pressed here, with nothing playing. True when this takes the press over, to
    /// play once it knows from where; false to play this device's own queue straight away.
    func claimPlay() -> Bool {
        if isMoving {
            playWhenDone = true
            return true
        }
        guard let app, app.credentials != nil else { return false }
        let hasPeers = !(players?.paired.isEmpty ?? true)
        // A paired device heard from lately -- followed, or answering a look -- is asked
        // first: reachable, it answers in a tenth of a second.
        if hasPeers, let heard = lastAnswerAt, Date.now.timeIntervalSince(heard) < 120 {
            run(play: true)
            return true
        }
        // Otherwise this device plays at once, and whether another has newer music is
        // looked at as it plays. Waiting first on a laptop that was off cost every press a
        // second, and from the lock screen the music then did not start at all.
        if hasPeers || serverIsStale(within: 60) {
            checkAfterPlaying(localSavedAt: app.player.lastSavedAt, list: app.player.queue.listID)
        }
        return false
    }

    /// Play went ahead here without asking: if another device turns out to have been
    /// playing, or to have newer music, the music moves over to it after all.
    private func checkAfterPlaying(localSavedAt: Date?, list: UUID) {
        guard !isMoving, let app, let players else { return }
        isMoving = true
        Task {
            let askServer = serverIsStale(within: 60)
            async let fromServer = serverQueue(asking: askServer, within: 4)
            let answers = await askAll(players.paired, players: players)
            let server = await fromServer
            if askServer { serverLookedAt = .now }
            let player = app.player
            let choice = HandoffChoice.choose(
                peers: answers.map(\.now),
                serverSavedAt: server?.changedAt,
                localSavedAt: localSavedAt
            )
            await record("played at once: \(answers.count) of \(players.paired.count) paired answered → \(choice)")
            isMoving = false
            // Only over the press it followed: not if something else has been put on since.
            guard player.queue.listID == list, player.remote == nil, player.video == nil else { return }
            switch choice {
            case .takeOver(let id), .continueFrom(let id):
                guard let answer = answers.first(where: { $0.now.id == id }) else { return }
                isMoving = true
                await bring(from: answer, play: true)
                isMoving = false
            case .server:
                guard let server else { return }
                let index = server.currentID.flatMap { id in server.songs.firstIndex { $0.id == id } } ?? 0
                taken = nil
                player.adopt(songs: server.songs, index: index, positionSeconds: server.positionSeconds,
                             source: "From \(server.deviceName)", uploading: false)
                player.play(handingOff: false)
                lastMove = (server.deviceName, .now)
            case .here:
                break
            }
        }
    }

    /// The app came to the front, or the desktop's window was focused. With nothing
    /// playing here, the player catches up with wherever the music is, paused.
    func look() {
        searchWait = 3
        startFollowing()
        guard !isMoving, let player = app?.player, !player.isPlaying, player.remote == nil,
              player.video == nil, app?.credentials != nil
        else { return }
        run(play: false)
    }

    /// The phone's app coming to the front (true) or going to the background (false).
    func setActive(_ active: Bool) {
        guard active != isActive || (active && follower == nil) else { return }
        isActive = active
        if active {
            searchWait = 3
            startFollowing()
        } else {
            stopFollowing()
        }
    }

    private func run(play: Bool) {
        isMoving = true
        playWhenDone = false
        Task {
            await move(play: play)
            // Pressed while looking: what the look found is a moment old, so ask again.
            if !play, playWhenDone {
                playWhenDone = false
                await move(play: true)
            }
            isMoving = false
        }
    }

    /// Every paired device's `/v1/now`, all at once; the ones that answered. Notes who
    /// went quiet, so the next press does not wait as long on them.
    private func askAll(_ computers: [RemotePlayers.Computer], players: RemotePlayers) async -> [Answer] {
        let silent = silentSince
        let answers: [Answer] = await withTaskGroup(of: Answer?.self) { group in
            for computer in computers {
                let recentlySilent = silent[computer.id].map { Date.now.timeIntervalSince($0) < 300 } ?? false
                group.addTask {
                    guard let reply = await players.ask(
                        computer, "v1/now", as: RemoteNow.self, within: recentlySilent ? 0.5 : 1.2
                    ) else { return nil }
                    return Answer(computer: computer, now: reply.answer, base: reply.base, roundTrip: reply.roundTrip, at: reply.at)
                }
            }
            var answers: [Answer] = []
            for await answer in group {
                if let answer { answers.append(answer) }
            }
            return answers
        }
        let answered = Set(answers.map(\.computer.id))
        for computer in computers {
            if answered.contains(computer.id) {
                silentSince[computer.id] = nil
            } else if silentSince[computer.id] == nil {
                silentSince[computer.id] = .now
            }
        }
        if !answers.isEmpty { lastAnswerAt = .now }
        return answers
    }

    private func serverQueue(asking: Bool, within timeout: TimeInterval) async -> QueueSync.Remote? {
        guard asking, let app else { return nil }
        return await app.queueSync.newest(within: timeout)
    }

    private func serverIsStale(within seconds: TimeInterval) -> Bool {
        serverLookedAt.map { Date.now.timeIntervalSince($0) > seconds } ?? true
    }

    // MARK: - Moving

    private struct Answer: Sendable {
        var computer: RemotePlayers.Computer
        var now: RemoteNow
        var base: URL
        var roundTrip: TimeInterval
        var at: Date
    }

    private func move(play: Bool) async {
        guard let app, let players else {
            if play { app?.player.play(handingOff: false) }
            return
        }
        let player = app.player
        let computers = players.paired

        // A look always asks the server; a press only when it has not been asked lately.
        let askServer = !play || serverIsStale(within: 60)
        async let fromServer = serverQueue(asking: askServer, within: play ? 1.5 : 4)

        let answers = await askAll(computers, players: players)
        let server = await fromServer
        if askServer { serverLookedAt = .now }

        let answered = Set(answers.map(\.computer.id))
        if !play, answered.count < computers.count { players.lookAround() }

        // While this was asking, something may have started here: then it stays.
        guard !player.isPlaying, player.remote == nil else { return }

        let choice = HandoffChoice.choose(
            peers: answers.map(\.now),
            serverSavedAt: server?.changedAt,
            localSavedAt: player.lastSavedAt
        )
        await record("\(play ? "play pressed" : "looked"): \(answers.count) of \(computers.count) paired answered\(askServer ? ", server \(server.map { "saved by \($0.deviceName)" } ?? "had nothing newer")" : "") → \(choice)")

        switch choice {
        case .takeOver(let id), .continueFrom(let id):
            guard let answer = answers.first(where: { $0.now.id == id }) else { break }
            await bring(from: answer, play: play)
            if !play, answer.now.state.isPlaying { follow(answer) }
            return
        case .server:
            guard let server else { break }
            let index = server.currentID.flatMap { id in server.songs.firstIndex { $0.id == id } } ?? 0
            taken = nil
            player.adopt(
                songs: server.songs,
                index: index,
                positionSeconds: server.positionSeconds,
                source: "From \(server.deviceName)",
                uploading: false
            )
            lastMove = (server.deviceName, .now)
        case .here:
            break
        }
        if play { player.play(handingOff: false) }
    }

    /// Takes over the queue `answer` describes: at its exact place, playing if `play`,
    /// and the other device paused once this one is sounding.
    private func bring(from answer: Answer, play: Bool, refetch: Bool = false) async {
        guard let app, let players else { return }
        let player = app.player
        // Playing here now: whatever was being followed is this, and is let go below.
        if play { clearFollow() }
        var now = answer.now
        var base = answer.base
        // When the other device read its time, by this one's clock.
        var readAt = answer.at.addingTimeInterval(-answer.roundTrip / 2)

        let queue: RemoteHandoffQueue
        var position = now.state.position
        if !refetch, let taken, taken.peerID == now.id, taken.queue.listID == now.listID,
           taken.queue.songs.count == now.count {
            queue = taken.queue
        } else {
            guard let reply = await players.ask(answer.computer, "v1/queue", as: RemoteHandoffQueue.self, within: 10),
                  !reply.answer.songs.isEmpty
            else {
                await record("couldn't fetch \(answer.computer.name)'s queue")
                if play { player.play(handingOff: false) }
                return
            }
            queue = reply.answer
            taken = (now.id, queue)
            position = queue.position
            // A long queue takes a while to come: where the other has got to, once more.
            if position != now.state.position || Date.now.timeIntervalSince(answer.at) > 1,
               let again = await players.ask(answer.computer, "v1/now", as: RemoteNow.self, within: 1.2),
               again.answer.listID == queue.listID {
                now = again.answer
                base = again.base
                readAt = again.at.addingTimeInterval(-again.roundTrip / 2)
                position = now.state.position
            }
        }
        guard queue.songs.indices.contains(position) else {
            if play { player.play(handingOff: false) }
            return
        }

        let state = now.state
        func theirPlace() -> Double { state.elapsed(after: Date.now.timeIntervalSince(readAt)) }
        player.adopt(
            songs: queue.songs,
            index: position,
            positionSeconds: theirPlace(),
            source: queue.source.isEmpty ? "From \(now.name)" : queue.source,
            station: queue.station,
            uploading: false
        )
        lastMove = (now.name, .now)
        guard play else { return }

        let takingOver = state.isPlaying
        if takingOver {
            // Opening the track took time, during which the other kept playing.
            await player.waitUntilOpened(atMost: 4)
            player.seek(to: theirPlace() + Self.startLead)
        }
        player.play(handingOff: false)
        if takingOver {
            await player.waitUntilSounding(atMost: 1.5)
            await players.release(answer.computer, at: base)
        }
        let song = queue.songs[position].title
        await record("took “\(song)” from \(now.name) at \(LogReport.clock(player.elapsed))\(takingOver ? ", and paused it there" : "")")
    }

    // MARK: - Following

    private var canFollow: Bool {
        guard isActive, !isMoving, let app, app.credentials != nil else { return false }
        let player = app.player
        return !player.isPlaying && player.remote == nil && player.video == nil
    }

    private func startFollowing() {
        guard isActive, follower == nil else { return }
        follower = Task { [weak self] in
            while !Task.isCancelled {
                guard let wait = await self?.followStep() else { return }
                try? await Task.sleep(for: .seconds(wait))
            }
        }
    }

    /// The time, four times a second, as the player's own ticks would move it: only while
    /// a device being followed is playing. Always on, it woke the app four times a second
    /// for nothing.
    private func updateTicker() {
        let moving = followedState.map { $0.state.isPlaying && !$0.state.isBuffering } ?? false
        if moving, ticker == nil {
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    self?.tick()
                }
            }
        } else if !moving, let running = ticker {
            running.cancel()
            ticker = nil
            tick()
        }
    }

    private func stopFollowing() {
        follower?.cancel()
        ticker?.cancel()
        follower = nil
        ticker = nil
        clearFollow()
    }

    private func clearFollow() {
        followed = nil
        followedState = nil
        followedList = nil
        followFailures = 0
        if following != nil { following = nil }
        app?.player.endFollowing()
        updateTicker()
    }

    /// Starts following what `answer` says, its queue already made this device's own.
    private func follow(_ answer: Answer) {
        followed = (answer.computer, answer.base)
        followedState = (answer.now.state, answer.at.addingTimeInterval(-answer.roundTrip / 2))
        followedList = app?.player.queue.listID
        followFailures = 0
        if following != answer.now.name { following = answer.now.name }
        updateTicker()
    }

    /// One look at the followed device, or for one to follow. How long to wait after.
    private func followStep() async -> TimeInterval {
        guard let app, let players else { return 5 }
        let player = app.player
        if player.isPlaying {
            // Something started here while a device was being followed as it played: the
            // music has moved here, so that one stops.
            if let followed, followedState?.state.isPlaying == true {
                await players.release(followed.computer, at: followed.base)
                await record("started playing here, so paused \(followed.computer.name)")
            }
            clearFollow()
            return 2
        }
        guard canFollow else {
            clearFollow()
            return 2
        }

        if let current = followed {
            guard let reply = await players.ask(current.computer, "v1/now", as: RemoteNow.self, within: 1.5) else {
                followFailures += 1
                // Gone quiet: the last of it stays on screen, standing still.
                if followFailures >= 3 {
                    if var last = followedState {
                        last.state.elapsed = last.state.elapsed(after: Date.now.timeIntervalSince(last.readAt))
                        last.state.isPlaying = false
                        followedState = (last.state, .now)
                    }
                    followed = nil
                    if following != nil { following = nil }
                    updateTicker()
                }
                return 1
            }
            guard canFollow, followed?.computer.id == current.computer.id else { return 1 }
            followFailures = 0
            await keepUp(with: Answer(computer: current.computer, now: reply.answer, base: reply.base, roundTrip: reply.roundTrip, at: reply.at))
            return 1
        }

        // Following nothing: is any paired device playing? Every few seconds while one
        // answers; less and less often, to every fifteen, while none does -- a phone asleep
        // in a pocket, a laptop shut -- since each look wakes the network for nothing.
        let computers = players.paired
        guard !computers.isEmpty else { return 15 }
        let answers = await askAll(computers, players: players)
        searchWait = answers.isEmpty ? min(searchWait * 2, 15) : 3
        guard canFollow, followed == nil,
              let playing = answers.first(where: { $0.now.state.isPlaying && $0.now.count > 0 })
        else { return searchWait }
        await keepUp(with: playing)
        return 1
    }

    /// Shows what the followed device says: its track, and the time from it.
    private func keepUp(with answer: Answer) async {
        guard let player = app?.player else { return }
        let now = answer.now
        guard now.count > 0 else { return }
        let readAt = answer.at.addingTimeInterval(-answer.roundTrip / 2)
        let place = now.state.elapsed(after: Date.now.timeIntervalSince(readAt))
        let index = now.state.position
        let holdsTheirs = followedList == player.queue.listID && taken?.peerID == now.id
            && taken?.queue.listID == now.listID && player.queue.order.count == now.count
        if holdsTheirs, player.queue.order.indices.contains(index),
           player.queue.tracks.indices.contains(player.queue.order[index]),
           player.queue.tracks[player.queue.order[index]].id == now.state.song?.id {
            if player.queue.position != index { player.follow(to: index, at: place) }
        } else {
            // Another list there, or this one changed here: the whole of it, once.
            await bring(from: answer, play: false, refetch: followedList != nil)
            guard canFollow else { return }
        }
        follow(answer)
    }

    private func tick() {
        guard let followed = followedState, canFollow, let player = app?.player else { return }
        player.showFollowed(
            elapsed: followed.state.elapsed(after: Date.now.timeIntervalSince(followed.readAt)),
            playing: followed.state.isPlaying && !followed.state.isBuffering
        )
    }

    private func record(_ line: String) async {
        await Diagnostics.shared.record("handoff", line)
    }
}
