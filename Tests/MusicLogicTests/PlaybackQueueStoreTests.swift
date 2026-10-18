import Foundation
import Testing

@testable import MusicLogic

/// The queue on disk: two files, so that a 28,000-track list is not written again every
/// time the position moves, and a relaunch still comes back exactly where it was.
struct PlaybackQueueStoreTests {
    private func songs(_ count: Int) -> [Song] {
        (1...count).map { Song(id: "s\($0)", title: "Track \($0)") }
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("queue-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func listFile(in directory: URL) -> URL { directory.appendingPathComponent("queue-list.json") }
    private func positionFile(in directory: URL) -> URL { directory.appendingPathComponent("queue-position.json") }

    @Test func theListIDChangesWithTheListAndNotWithThePosition() {
        var queue = PlaybackQueue.make(tracks: songs(5), startingAt: 0, shuffled: false, source: "Album")
        let made = queue.listID

        _ = queue.advance()
        queue.jump(toOrderIndex: 3)
        queue.repeatMode = .all
        #expect(queue.listID == made)

        queue.append([Song(id: "x", title: "X")])
        let appended = queue.listID
        #expect(appended != made)

        queue.move(fromOrderIndex: 4, toOrderIndex: 1)
        #expect(queue.listID != appended)

        let moved = queue.listID
        queue.shuffle(keepingCurrent: true)
        #expect(queue.listID != moved)
    }

    @Test func aSavedQueueComesBackAsItWas() async throws {
        let folder = try directory()
        var queue = PlaybackQueue.make(tracks: songs(6), startingAt: 3, shuffled: true, source: "Kid A")
        queue.repeatMode = .all
        queue.insertNext([Song(id: "next", title: "Next")])
        let savedAt = Date(timeIntervalSince1970: 1_000_000)

        await PlaybackQueueStore(directory: folder).save(
            QueueSnapshot(queue: queue, positionSeconds: 42.5, savedAt: savedAt)
        )
        let restored = try #require(await PlaybackQueueStore(directory: folder).load())

        #expect(restored.queue.tracks.map(\.id) == queue.tracks.map(\.id))
        #expect(restored.queue.order == queue.order)
        #expect(restored.queue.position == queue.position)
        #expect(restored.queue.current?.id == queue.current?.id)
        #expect(restored.queue.repeatMode == .all)
        #expect(restored.queue.isShuffled)
        #expect(restored.queue.sourceDescription == "Kid A")
        #expect(restored.queue.lastAddedTrackIndex == queue.lastAddedTrackIndex)
        #expect(restored.queue.listID == queue.listID)
        #expect(restored.positionSeconds == 42.5)
        #expect(restored.savedAt == savedAt)
    }

    /// The point of the split: moving on a track writes the position and nothing else.
    @Test func anUnchangedListIsNotWrittenAgain() async throws {
        let folder = try directory()
        let store = PlaybackQueueStore(directory: folder)
        var queue = PlaybackQueue.make(tracks: songs(4), startingAt: 0, shuffled: false, source: "Album")
        await store.save(QueueSnapshot(queue: queue, positionSeconds: 0, savedAt: .now))

        // Gone from disk: if the next save wrote it, it would be back.
        try FileManager.default.removeItem(at: listFile(in: folder))
        _ = queue.advance()
        await store.save(QueueSnapshot(queue: queue, positionSeconds: 12, savedAt: .now))
        #expect(!FileManager.default.fileExists(atPath: listFile(in: folder).path))
        #expect(FileManager.default.fileExists(atPath: positionFile(in: folder).path))

        queue.append([Song(id: "x", title: "X")])
        await store.save(QueueSnapshot(queue: queue, positionSeconds: 12, savedAt: .now))
        #expect(FileManager.default.fileExists(atPath: listFile(in: folder).path))
    }

    /// The format before the split, read once, so an update does not lose the queue.
    @Test func aQueueSavedInTheOldSingleFileIsRestoredAndMovedOver() async throws {
        let folder = try directory()
        let legacy = folder.appendingPathComponent("queue.json")
        var queue = PlaybackQueue.make(tracks: songs(5), startingAt: 2, shuffled: false, source: "Album")
        queue.repeatMode = .one
        let old = QueueSnapshot(queue: queue, positionSeconds: 30, savedAt: Date(timeIntervalSince1970: 5))
        try JSONEncoder().encode(old).write(to: legacy)

        let store = PlaybackQueueStore(directory: folder, legacyURL: legacy)
        let restored = try #require(await store.load())
        #expect(restored.queue.tracks.map(\.id) == queue.tracks.map(\.id))
        #expect(restored.queue.current?.id == "s3")
        #expect(restored.queue.repeatMode == .one)
        #expect(restored.positionSeconds == 30)

        await store.save(restored)
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        let again = try #require(await PlaybackQueueStore(directory: folder, legacyURL: legacy).load())
        #expect(again.queue.current?.id == "s3")
        #expect(again.positionSeconds == 30)
    }

    /// A crash between writing the list and the position leaves the position of the list
    /// before. The track playing is found again by its id rather than by an index that
    /// now means something else.
    @Test func aPositionSavedWithAnEarlierListFindsItsTrackByID() async throws {
        let folder = try directory()
        var queue = PlaybackQueue.make(tracks: songs(5), startingAt: 2, shuffled: false, source: "Album")
        await PlaybackQueueStore(directory: folder).save(QueueSnapshot(queue: queue, positionSeconds: 20, savedAt: .now))
        let earlierPosition = try Data(contentsOf: positionFile(in: folder))

        // Two tracks put in before the one playing, then the earlier position put back.
        queue.insert([Song(id: "a", title: "A"), Song(id: "b", title: "B")], before: 0)
        await PlaybackQueueStore(directory: folder).save(QueueSnapshot(queue: queue, positionSeconds: 20, savedAt: .now))
        try earlierPosition.write(to: positionFile(in: folder))

        let restored = try #require(await PlaybackQueueStore(directory: folder).load())
        #expect(restored.queue.current?.id == "s3")
        #expect(restored.positionSeconds == 20)
    }
}

private extension PlaybackQueue {
    /// Puts songs in ahead of an order index, the way no menu does, to move the current
    /// track's index without changing which track it is.
    mutating func insert(_ songs: [Song], before orderIndex: Int) {
        let start = tracks.count
        tracks.append(contentsOf: songs)
        order.insert(contentsOf: start..<tracks.count, at: orderIndex)
        if orderIndex <= position { position += songs.count }
    }
}
