import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
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
/// **Following.** While this device is idle -- the phone on screen, the desktop's window
/// showing -- it follows the paired device that is playing: the same track, the time
/// moving, on to the next track when that one moves on, the lyrics with it. Each paired
/// device is watched over one open connection (`/v1/now/events`) that says something only
/// when there is news -- a track, a pause, a seek -- and the time is worked out here in
/// between, so the device playing is not woken every second to be asked. An older build
/// without it is asked once a second while followed. Nothing is fetched to play until play
/// is pressed here. Play is still the one press that brings the music over. Starting
/// anything else here pauses the device being followed: the music moved here.
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

    /// The device being followed, by name, while this one is idle.
    private(set) var following: String?
    @ObservationIgnored private var followed: (computer: RemotePlayers.Computer, base: URL)?
    /// What it last said, and when it read it by this device's clock.
    @ObservationIgnored private var followedState: (state: RemoteState, readAt: Date)?
    /// This device's queue as it was made from the followed one, to know it still is.
    @ObservationIgnored private var followedList: UUID?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    /// One watch on each paired device, by id, while this one follows (`watch`).
    @ObservationIgnored private var watchers: [String: Task<Void, Never>] = [:]
    /// What each watched device said last, and what it has said that is not yet acted on.
    @ObservationIgnored private var latest: [String: Answer] = [:]
    @ObservationIgnored private var news: [String: Answer] = [:]
    @ObservationIgnored private var isCatchingUp = false
    @ObservationIgnored private var isObserving = false
    /// For the watch streams: given up on after the silence a ping would have broken.
    @ObservationIgnored private let streaming: URLSessionConfiguration
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
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = RemoteControl.silence
        #if !canImport(FoundationNetworking)
        configuration.waitsForConnectivity = false
        #endif
        streaming = configuration
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
                             source: server.deviceName, uploading: false)
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
        startFollowing()
        guard !isMoving, let player = app?.player, !player.isPlaying, player.remote == nil,
              player.video == nil, app?.credentials != nil
        else { return }
        run(play: false)
    }

    /// The phone's app coming to the front (true) or going to the background (false).
    func setActive(_ active: Bool) {
        guard active != isActive || (active && watchers.isEmpty) else { return }
        isActive = active
        if active {
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
            reconsider()
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
                source: server.deviceName,
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
            source: queue.source.isEmpty ? now.name : queue.source,
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

    /// Idle here, with somewhere to show it: the phone on screen, the desktop's window up.
    private var shouldWatch: Bool {
        guard isActive, let app, app.credentials != nil else { return false }
        let player = app.player
        return !player.isPlaying && player.remote == nil && player.video == nil
    }

    private var canFollow: Bool { shouldWatch && !isMoving }

    private func startFollowing() {
        observeWatching()
        updateWatching()
    }

    /// Keeps the watching in step with whether this device is idle: no polling for it,
    /// the player and the paired devices say when it changes.
    private func observeWatching() {
        guard !isObserving, let app else { return }
        isObserving = true
        withObservationTracking {
            _ = app.credentials != nil
            _ = app.player.isPlaying
            _ = app.player.remote == nil
            _ = app.player.video == nil
            _ = players?.paired.map(\.id)
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.isObserving = false
                self.observeWatching()
                self.updateWatching()
            }
        }
    }

    private func updateWatching() {
        guard shouldWatch, let players else {
            // Playing here while the device followed was playing: the music has moved here,
            // so that one stops.
            if let followed, followedState?.state.isPlaying == true, app?.player.isPlaying == true,
               let players {
                Task {
                    await players.release(followed.computer, at: followed.base)
                    await record("started playing here, so paused \(followed.computer.name)")
                }
            }
            stopWatching()
            clearFollow()
            return
        }
        let paired = players.paired
        let ids = Set(paired.map(\.id))
        for (id, watcher) in watchers where !ids.contains(id) {
            watcher.cancel()
            watchers[id] = nil
            latest[id] = nil
        }
        if let followed, !ids.contains(followed.computer.id) { clearFollow() }
        for computer in paired where watchers[computer.id] == nil {
            let id = computer.id
            watchers[id] = Task { [weak self] in await self?.watch(id) }
        }
    }

    private func stopWatching() {
        for watcher in watchers.values { watcher.cancel() }
        watchers = [:]
        latest = [:]
        news = [:]
    }

    private func stopFollowing() {
        stopWatching()
        ticker?.cancel()
        ticker = nil
        clearFollow()
    }

    /// Keeps up with one paired device while this one watches. Asked once, where it
    /// answers; then told, over a stream that stays open, whenever what it plays changes,
    /// with a ping every fifteen seconds and nothing else. Out of reach, it is looked for
    /// again less and less often, to every fifteen seconds -- a phone asleep in a pocket, a
    /// laptop shut -- since each look wakes the network for nothing.
    private func watch(_ id: String) async {
        var wait: TimeInterval = 3
        var streams = true
        while !Task.isCancelled {
            // As it is known now: where it was last reached, and every address it gave.
            guard let players, let computer = players.paired.first(where: { $0.id == id }) else { return }
            let quiet = silentSince[computer.id].map { Date.now.timeIntervalSince($0) < 300 } ?? false
            let reply = await players.ask(computer, "v1/now", as: RemoteNow.self, within: quiet ? 0.5 : 1.2)
            guard !Task.isCancelled else { return }
            if let reply {
                silentSince[computer.id] = nil
                wait = 3
                heard(Answer(computer: computer, now: reply.answer, base: reply.base, roundTrip: reply.roundTrip, at: reply.at))
                if streams {
                    let started = Date.now
                    streams = await listen(to: computer, at: reply.base)
                    guard !Task.isCancelled else { return }
                    // Ended after a good while: asked again at once. Straight away, or not
                    // there to listen to: a second's rest, so nothing spins.
                    wait = streams && Date.now.timeIntervalSince(started) > 10 ? 0 : 1
                } else {
                    // An older build: asked each second while followed.
                    wait = followed?.computer.id == computer.id ? 1 : 3
                }
            } else {
                if silentSince[computer.id] == nil { silentSince[computer.id] = .now }
                if followed?.computer.id == computer.id { standStill() }
                wait = min(max(wait, 1.5) * 2, 15)
            }
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
        }
    }

    /// Listens to `computer`'s news until the stream ends. False when it has no such
    /// stream, being an older build.
    private func listen(to computer: RemotePlayers.Computer, at base: URL) async -> Bool {
        guard let token = computer.token else { return true }
        var request = URLRequest(url: base.appendingPathComponent("v1/now/events"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = RemoteControl.silence
        do {
            let (status, lines) = try await RemoteLines.open(request, configuration: streaming)
            if status == 404 { return false }
            guard status == 200 else { return true }
            var parser = EventStream.Parser()
            let decoder = JSONDecoder()
            for try await line in lines {
                lastAnswerAt = .now
                guard let event = parser.feed(line), event.name == "now",
                      let now = try? decoder.decode(RemoteNow.self, from: Data(event.data.utf8))
                else { continue }
                heard(Answer(computer: computer, now: now, base: base, roundTrip: 0, at: .now))
            }
        } catch {}
        return true
    }

    /// News from a watched device, acted on in order: following it may mean fetching its
    /// queue, during which more may come.
    private func heard(_ answer: Answer) {
        lastAnswerAt = .now
        latest[answer.computer.id] = answer
        news[answer.computer.id] = answer
        guard !isCatchingUp else { return }
        isCatchingUp = true
        Task {
            while let next = news.first {
                news[next.key] = nil
                await consider(next.value)
            }
            isCatchingUp = false
        }
    }

    /// What was heard while a move was under way, which was not acted on then.
    private func reconsider() {
        guard canFollow else { return }
        for answer in latest.values { heard(answer) }
    }

    private func consider(_ answer: Answer) async {
        guard canFollow else { return }
        if followed?.computer.id == answer.computer.id {
            await keepUp(with: answer)
        } else if answer.now.state.isPlaying, answer.now.count > 0,
                  followed == nil || followedState?.state.isPlaying != true {
            await keepUp(with: answer)
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

    private func clearFollow() {
        followed = nil
        followedState = nil
        followedList = nil
        if following != nil { following = nil }
        app?.player.endFollowing()
        updateTicker()
    }

    /// The device followed has gone quiet: the last of it stays on screen, standing still.
    private func standStill() {
        if var last = followedState {
            last.state.elapsed = last.state.elapsed(after: Date.now.timeIntervalSince(last.readAt))
            last.state.isPlaying = false
            followedState = (last.state, .now)
        }
        followed = nil
        if following != nil { following = nil }
        updateTicker()
    }

    /// Starts following what `answer` says, its queue already made this device's own.
    private func follow(_ answer: Answer) {
        followed = (answer.computer, answer.base)
        followedState = (answer.now.state, answer.at.addingTimeInterval(-answer.roundTrip / 2))
        followedList = app?.player.queue.listID
        if following != answer.now.name { following = answer.now.name }
        updateTicker()
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
