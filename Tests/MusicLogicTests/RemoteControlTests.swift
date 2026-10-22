import Foundation
import Testing

@testable import MusicLogic

/// The wire between the phone and the desktop. Both ends are this code, so what is tested
/// here is what each end can rely on of the other: the JSON a terminal can type, the
/// window's arithmetic, and the phone's translation of its places back into the desktop's.
struct RemoteControlTests {
    private func songs(_ count: Int) -> [Song] {
        (0..<count).map { Song(id: "s\($0)", title: "Track \($0)") }
    }

    private func json(_ command: RemoteCommand) throws -> [String: Any] {
        let data = try JSONEncoder().encode(command)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - Commands

    @Test func aCommandIsFlatJSONWithOnlyWhatItUses() throws {
        let object = try json(.seek(to: 42))
        #expect(object.count == 2)
        #expect(object["action"] as? String == "seek")
        #expect(object["seconds"] as? Double == 42)
    }

    @Test func aTypedCommandDecodes() throws {
        let typed = #"{"action": "move", "index": 3, "to": 7}"#
        let command = try JSONDecoder().decode(RemoteCommand.self, from: Data(typed.utf8))
        #expect(command == .at(.move, 3, to: 7))
    }

    @Test func playingSongsCarriesTheSongsAndLeavesDefaultsOut() throws {
        let command = RemoteCommand.playSongs(songs(3), from: 1, source: "Kid A")
        let object = try json(command)
        #expect(object["shuffled"] == nil)
        #expect(object["paused"] == nil)
        #expect(object["seconds"] == nil)
        let decoded = try JSONDecoder().decode(RemoteCommand.self, from: JSONEncoder().encode(command))
        #expect(decoded == command)
        #expect(decoded.songs?.map(\.id) == ["s0", "s1", "s2"])
    }

    // MARK: - Window

    @Test func aShortQueueIsSentWhole() {
        #expect(RemoteQueue.range(around: 0, count: 12) == 0..<12)
        #expect(RemoteQueue.range(around: 11, count: 12) == 0..<12)
    }

    /// Moved in steps of fifty, so a long queue is re-sent every fifty tracks, and always
    /// with at least `behind` tracks of history and a couple of hundred to come.
    @Test func aLongQueuesWindowMovesInSteps() {
        let count = 28_000
        #expect(RemoteQueue.range(around: 0, count: count) == 0..<300)
        #expect(RemoteQueue.range(around: 74, count: count) == 0..<300)
        #expect(RemoteQueue.range(around: 75, count: count) == 50..<350)
        #expect(RemoteQueue.range(around: 124, count: count) == 50..<350)
        for position in stride(from: 0, to: 5_000, by: 7) {
            let range = RemoteQueue.range(around: position, count: count)
            #expect(range.contains(position))
            #expect(position - range.lowerBound >= min(position, RemoteQueue.behind))
            #expect(range.upperBound - position > 200)
        }
    }

    @Test func theEndOfALongQueueKeepsAFullWindow() {
        #expect(RemoteQueue.range(around: 999, count: 1_000) == 700..<1_000)
    }

    @Test func theWindowIsInPlayOrder() {
        var queue = PlaybackQueue.make(tracks: songs(5), startingAt: 0, shuffled: false, source: "Mix")
        queue.order = [4, 2, 0, 1, 3]
        queue.position = 1
        let window = RemoteQueue(queue)
        #expect(window.offset == 0)
        #expect(window.count == 5)
        #expect(window.songs.map(\.id) == ["s4", "s2", "s0", "s1", "s3"])
        #expect(window.source == "Mix")
    }

    // MARK: - Mirror

    private func mirror(count: Int, position: Int) -> RemoteMirror {
        let queue = PlaybackQueue.make(tracks: songs(count), startingAt: position, shuffled: false, source: "Library")
        var mirror = RemoteMirror()
        mirror.apply(RemoteQueue(queue))
        var state = RemoteState()
        state.song = queue.current
        state.position = position
        mirror.apply(state, at: .now)
        return mirror
    }

    @Test func thePhonesQueueIsTheWindowNumberedFromZero() {
        let mirror = mirror(count: 1_000, position: 130)
        #expect(mirror.window?.offset == 100)
        #expect(mirror.queue.position == 30)
        #expect(mirror.queue.current?.id == "s130")
        #expect(mirror.queue.order == Array(0..<300))
    }

    @Test func placesInTheWindowAreTranslatedBack() {
        let mirror = mirror(count: 1_000, position: 130)
        #expect(mirror.translate(.at(.jump, 35)) == .at(.jump, 135))
        #expect(mirror.translate(.at(.move, 31, to: 40)) == .at(.move, 131, to: 140))
        #expect(mirror.translate(.seek(to: 10)) == .seek(to: 10))
    }

    /// The queue view keys its rows by the queue's list; a track change must not rebuild them.
    @Test func aNewPositionKeepsTheList() {
        var mirror = mirror(count: 20, position: 3)
        let list = mirror.queue.listID
        var state = mirror.state
        state.position = 4
        state.song = Song(id: "s4", title: "Track 4")
        mirror.apply(state, at: .now)
        #expect(mirror.queue.listID == list)
        #expect(mirror.queue.current?.id == "s4")
    }

    @Test func aSeekShowsAtOnce() {
        var mirror = mirror(count: 5, position: 0)
        let now = Date.now
        mirror.anticipate(.seek(to: 90), at: now)
        #expect(mirror.elapsed(at: now) == 90)
    }

    // MARK: - Time

    @Test func timeMovesOnlyWhilePlaying() {
        var state = RemoteState()
        state.elapsed = 10
        state.duration = 100
        #expect(state.elapsed(after: 5) == 10)
        state.isPlaying = true
        #expect(state.elapsed(after: 5) == 15)
        state.speed = 1.5
        #expect(state.elapsed(after: 4) == 16)
        #expect(state.elapsed(after: 500) == 100)
        state.isBuffering = true
        #expect(state.elapsed(after: 5) == 10)
    }

    @Test func onlyWhatExtrapolationMissesIsNews() {
        var previous = RemoteState()
        previous.isPlaying = true
        previous.elapsed = 10
        previous.duration = 200

        var later = previous
        later.elapsed = 13.2
        #expect(!later.differs(from: previous, after: 3))

        var seeked = previous
        seeked.elapsed = 60
        #expect(seeked.differs(from: previous, after: 3))

        var paused = later
        paused.isPlaying = false
        #expect(paused.differs(from: previous, after: 3))

        var louder = later
        louder.volume = 0.5
        #expect(louder.differs(from: previous, after: 3))
    }

    // MARK: - Event stream

    @Test func eventsAreReadAtTheirDataLine() {
        var parser = EventStream.Parser()
        let lines = [
            ": ping",
            "event: state",
            #"data: {"isPlaying":true}"#,
            // URLSession's line reader drops the blank line that ends an event.
            "event: queue\r",
            "data:{}",
            "",
            "data: bare",
        ]
        let events = lines.compactMap { parser.feed($0) }
        #expect(events == [
            EventStream.Event(name: "state", data: #"{"isPlaying":true}"#),
            EventStream.Event(name: "queue", data: "{}"),
            EventStream.Event(name: "message", data: "bare"),
        ])
    }

    @Test func aFrameParsesBack() throws {
        let data = String(decoding: try JSONEncoder().encode(RemoteState()), as: UTF8.self)
        var parser = EventStream.Parser()
        let events = EventStream.frame("state", data).split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { parser.feed($0) }
        #expect(events == [EventStream.Event(name: "state", data: data)])
    }
}
