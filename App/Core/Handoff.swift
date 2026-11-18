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
        // Without paired devices only the server can say, and it was asked a moment ago.
        guard hasPeers || serverIsStale(within: 60) else { return false }
        run(play: true)
        return true
    }

    /// The app came to the front, or the desktop's window was focused. With nothing
    /// playing here, the player catches up with wherever the music is, paused.
    func look() {
        guard !isMoving, let player = app?.player, !player.isPlaying, player.remote == nil,
              player.video == nil, app?.credentials != nil
        else { return }
        run(play: false)
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

        let silent = silentSince
        let answers: [Answer] = await withTaskGroup(of: Answer?.self) { group in
            for computer in computers {
                let recentlySilent = silent[computer.id].map { Date.now.timeIntervalSince($0) < 300 } ?? false
                group.addTask {
                    guard let reply = await players.ask(
                        computer, "v1/now", as: RemoteNow.self, within: recentlySilent ? 0.4 : 1.2
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
        let server = await fromServer
        if askServer { serverLookedAt = .now }

        let answered = Set(answers.map(\.computer.id))
        for computer in computers {
            if answered.contains(computer.id) {
                silentSince[computer.id] = nil
            } else if silentSince[computer.id] == nil {
                silentSince[computer.id] = .now
            }
        }
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
    private func bring(from answer: Answer, play: Bool) async {
        guard let app, let players else { return }
        let player = app.player
        var now = answer.now
        var base = answer.base
        // When the other device read its time, by this one's clock.
        var readAt = answer.at.addingTimeInterval(-answer.roundTrip / 2)

        let queue: RemoteHandoffQueue
        var position = now.state.position
        if let taken, taken.peerID == now.id, taken.queue.listID == now.listID {
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

    private func record(_ line: String) async {
        await Diagnostics.shared.record("handoff", line)
    }
}
