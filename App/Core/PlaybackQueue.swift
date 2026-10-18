import Foundation

enum RepeatMode: String, Codable, Sendable, CaseIterable {
    case off, all, one

    var symbol: String {
        switch self {
        case .off, .all: return "repeat"
        case .one: return "repeat.1"
        }
    }

    var next: RepeatMode {
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }
}

/// The logical queue, independent of AVFoundation.
///
/// Shuffle is stored as a **permutation** rather than a shuffled copy of the array.
/// That makes un-shuffling exact, keeps "Up Next" stable across toggles, and keeps
/// the snapshot small.
struct PlaybackQueue: Codable, Sendable {
    /// Always the original, unshuffled order.
    var tracks: [Song] = [] { didSet { listID = UUID() } }
    /// A permutation of indices into `tracks`; the identity when unshuffled.
    var order: [Int] = [] { didSet { listID = UUID() } }
    /// Index into `order`, not into `tracks`.
    var position: Int = 0
    var repeatMode: RepeatMode = .off
    var isShuffled: Bool = false { didSet { listID = UUID() } }
    /// "Kid A", "Freedom" -- shown in the player as the source of the queue.
    var sourceDescription: String = "" { didSet { listID = UUID() } }
    /// Index into `tracks` of the last song put in with Play Next or Add to Up Next:
    /// where the next Add to Up Next goes. Optional so a queue saved before it existed
    /// still decodes.
    var lastAddedTrackIndex: Int? { didSet { listID = UUID() } }
    /// Set when the queue is a station, which tops itself up as it plays.
    var station: Station? { didSet { listID = UUID() } }

    /// Changes whenever the list does: the tracks, their order, or anything kept with
    /// them. Never for `position` or `repeatMode`, which change every track and with a
    /// tap. It is how the store knows whether the long part of the queue, which can be
    /// tens of thousands of songs, has to be written again, and how sync knows whether
    /// to upload it. Not saved in the queue's own coding: the store keeps it beside it.
    var listID = UUID()

    private enum CodingKeys: String, CodingKey {
        case tracks, order, position, repeatMode, isShuffled, sourceDescription, lastAddedTrackIndex, station
    }

    var isEmpty: Bool { tracks.isEmpty }

    var current: Song? {
        guard order.indices.contains(position) else { return nil }
        let index = order[position]
        return tracks.indices.contains(index) ? tracks[index] : nil
    }

    func upcoming(_ count: Int) -> [Song] {
        guard !order.isEmpty else { return [] }
        let start = position + 1
        guard start < order.count else { return [] }
        return order[start..<min(start + count, order.count)].map { tracks[$0] }
    }

    /// How many tracks follow the current one — without building them, which for a
    /// 28,000-track queue is what made checking it four times a second expensive.
    var upNextCount: Int { max(order.count - position - 1, 0) }
    var hasUpNext: Bool { upNextCount > 0 }

    /// Everything after the current track, for the queue view.
    var upNext: [Song] {
        upcoming(max(order.count - position - 1, 0))
    }

    /// What already played, oldest first: the queue view's Earlier tab.
    var earlier: [Song] {
        guard position > 0, position <= order.count else { return [] }
        return order[0..<position].compactMap { tracks.indices.contains($0) ? tracks[$0] : nil }
    }

    /// Plexamp offers Add to Up Next only once something has been added and is still to
    /// come: before that, "after the last thing you added" means nothing.
    var canAddToUpNext: Bool {
        upNextInsertionPoint != nil
    }

    /// The order index after which Add to Up Next inserts, when there is one.
    private var upNextInsertionPoint: Int? {
        guard let lastAddedTrackIndex,
              let orderIndex = order.firstIndex(of: lastAddedTrackIndex),
              orderIndex >= position
        else { return nil }
        return orderIndex
    }

    static func make(
        tracks: [Song],
        startingAt index: Int,
        shuffled: Bool,
        source: String,
        repeatMode: RepeatMode = .off,
        station: Station? = nil
    ) -> PlaybackQueue {
        var queue = PlaybackQueue(
            tracks: tracks,
            order: Array(tracks.indices),
            position: 0,
            repeatMode: repeatMode,
            isShuffled: false,
            sourceDescription: source,
            station: station
        )
        queue.position = queue.order.firstIndex(of: index) ?? 0

        // `keepingCurrent: false` on purpose. Pressing Shuffle should start on a
        // random track; keeping the current one pinned it to position 0, so shuffle
        // always began with track 1 and only the rest was random. Toggling shuffle
        // *during* playback is the opposite case and still keeps the current track --
        // see `toggleShuffle`.
        if shuffled { queue.shuffle(keepingCurrent: false) }
        return queue
    }

    mutating func shuffle(keepingCurrent: Bool) {
        guard !order.isEmpty else { return }

        let currentTrackIndex = order.indices.contains(position) ? order[position] : nil
        var shuffledOrder = Array(tracks.indices).shuffled()

        if keepingCurrent, let currentTrackIndex,
           let existing = shuffledOrder.firstIndex(of: currentTrackIndex) {
            shuffledOrder.swapAt(0, existing)
            position = 0
        } else {
            position = 0
        }

        order = shuffledOrder
        isShuffled = true
    }

    mutating func unshuffle() {
        guard isShuffled else { return }
        let currentTrackIndex = order.indices.contains(position) ? order[position] : 0
        order = Array(tracks.indices)
        position = currentTrackIndex
        isShuffled = false
    }

    /// Advances honouring the repeat mode. Returns false when the queue is done.
    mutating func advance() -> Bool {
        guard !order.isEmpty else { return false }

        switch repeatMode {
        case .one:
            return true // same track; the player seeks to zero
        case .off:
            guard position + 1 < order.count else { return false }
            position += 1
            return true
        case .all:
            position = (position + 1) % order.count
            return true
        }
    }

    mutating func rewind() -> Bool {
        guard !order.isEmpty else { return false }
        if position > 0 {
            position -= 1
            return true
        }
        if repeatMode == .all {
            position = order.count - 1
            return true
        }
        return false
    }

    mutating func jump(toOrderIndex index: Int) {
        guard order.indices.contains(index) else { return }
        position = index
    }

    /// Plexamp's Play Next: straight after the current track, ahead of anything added
    /// before.
    mutating func insertNext(_ songs: [Song]) {
        insert(songs, afterOrderIndex: position)
    }

    /// Plexamp's Add to Up Next: after the last thing added, so a run of additions plays
    /// in the order it was made — and straight after the current track when nothing
    /// added is still to come.
    mutating func addToUpNext(_ songs: [Song]) {
        insert(songs, afterOrderIndex: upNextInsertionPoint ?? position)
    }

    /// Plexamp's Add to Queue: the very end. Deliberately not an "addition" for Add to
    /// Up Next's purposes — that would push the next one to the end as well.
    mutating func append(_ songs: [Song]) {
        guard !songs.isEmpty else { return }
        let insertAt = tracks.count
        tracks.append(contentsOf: songs)
        order.append(contentsOf: Array(insertAt..<tracks.count))
    }

    private mutating func insert(_ songs: [Song], afterOrderIndex index: Int) {
        guard !songs.isEmpty else { return }
        let insertAt = tracks.count
        tracks.append(contentsOf: songs)
        let newIndices = Array(insertAt..<tracks.count)
        order.insert(contentsOf: newIndices, at: min(index + 1, order.count))
        lastAddedTrackIndex = newIndices.last
    }

    /// A Guest DJ's picks: placed where the DJ says, and not "additions" as far as Add to
    /// Up Next is concerned — those are yours.
    mutating func insertPicks(_ songs: [Song], afterOrderIndex index: Int) {
        let yours = lastAddedTrackIndex
        insert(songs, afterOrderIndex: index)
        lastAddedTrackIndex = yours
    }

    /// Removes every upcoming occurrence of these songs — a DJ's picks, when the DJ
    /// leaves. What already played, and what is playing, stay.
    mutating func removeUpcoming(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        for index in stride(from: order.count - 1, to: position, by: -1) {
            let track = order[index]
            if tracks.indices.contains(track), ids.contains(tracks[track].id) {
                remove(atOrderIndex: index)
            }
        }
    }

    /// Plexamp's Clear Play Queue: everything goes except the track playing, which plays on.
    mutating func clearAllButCurrent() {
        guard let current else {
            self = PlaybackQueue(repeatMode: repeatMode)
            return
        }
        tracks = [current]
        order = [0]
        position = 0
        isShuffled = false
        lastAddedTrackIndex = nil
    }

    mutating func remove(atOrderIndex index: Int) {
        guard order.indices.contains(index) else { return }
        let trackIndex = order.remove(at: index)

        // The track has to leave `tracks` as well, not just the running order.
        // `unshuffle()` rebuilds the order from `tracks.indices`, so leaving it behind
        // meant every song removed from the queue came back the moment shuffle was
        // switched off. Found by a test, not by use.
        guard tracks.indices.contains(trackIndex) else { return }
        tracks.remove(at: trackIndex)

        // Every remaining index above the removed one now points one slot too high.
        order = order.map { $0 > trackIndex ? $0 - 1 : $0 }
        if let last = lastAddedTrackIndex {
            lastAddedTrackIndex = last == trackIndex ? nil : (last > trackIndex ? last - 1 : last)
        }

        if index < position { position -= 1 }
        position = min(position, max(order.count - 1, 0))
    }

    mutating func move(fromOrderIndex source: Int, toOrderIndex destination: Int) {
        guard order.indices.contains(source) else { return }
        let value = order.remove(at: source)
        order.insert(value, at: min(destination, order.count))
    }
}

/// A saved queue: the queue plus where we were in the current track. Also the format the
/// whole queue was once written in, as one file, which `PlaybackQueueStore` still reads.
struct QueueSnapshot: Codable, Sendable {
    var queue: PlaybackQueue
    var positionSeconds: Double
    var savedAt: Date
}

/// Persists the queue so a relaunch resumes where you were.
///
/// In two files, because the queue is two very different things. The list -- every
/// track, the order, what it was started from -- can be tens of thousands of songs and
/// changes only when the queue is edited. Where it has got to -- the position, the
/// seconds into the track, the repeat mode -- changes on every track and every pause.
/// Written as one file, all of it was encoded and written for each of those: several
/// megabytes for a smart playlist of the whole library, every few minutes. Now the list
/// is written when its `listID` differs from the one on disk, and the position always,
/// which is a few dozen bytes.
///
/// The list is written first, and the position names the list it belongs to. A crash
/// between the two leaves a position for the previous list; on loading, that position
/// is found again in the new list by the current song's id, which is as close as it can
/// be got.
actor PlaybackQueueStore {
    private let listURL: URL
    private let positionURL: URL
    /// Where the whole queue used to be written. Read when the two files are not there
    /// yet, so the queue survives the update, and deleted once they are.
    private let legacyURL: URL?
    /// The list on disk, so an unchanged one is not written again.
    private var writtenListID: UUID?

    init(directory: URL, legacyURL: URL? = nil) {
        listURL = directory.appendingPathComponent("queue-list.json")
        positionURL = directory.appendingPathComponent("queue-position.json")
        self.legacyURL = legacyURL
    }

    /// Everything kept with the tracks: what changes only when the list does.
    private struct SavedList: Codable {
        var id: UUID
        var tracks: [Song]
        var order: [Int]
        var isShuffled: Bool
        var sourceDescription: String
        var lastAddedTrackIndex: Int?
        var station: Station?
    }

    private struct SavedPosition: Codable {
        var listID: UUID
        var position: Int
        /// To find the position again if the list on disk is not the one it was saved
        /// with.
        var currentID: String?
        var repeatMode: RepeatMode
        var positionSeconds: Double
        var savedAt: Date
    }

    func load() -> QueueSnapshot? {
        guard let listData = try? Data(contentsOf: listURL),
              let list = try? JSONDecoder().decode(SavedList.self, from: listData)
        else { return loadLegacy() }

        let saved = (try? Data(contentsOf: positionURL))
            .flatMap { try? JSONDecoder().decode(SavedPosition.self, from: $0) }

        var queue = PlaybackQueue(
            tracks: list.tracks,
            order: list.order,
            position: 0,
            repeatMode: saved?.repeatMode ?? .off,
            isShuffled: list.isShuffled,
            sourceDescription: list.sourceDescription,
            lastAddedTrackIndex: list.lastAddedTrackIndex,
            station: list.station
        )
        // Whether the saved position still points at the track it was saved on.
        var isSameTrack = false
        if let saved {
            if saved.listID == list.id {
                queue.position = saved.position
                isSameTrack = true
            } else if let currentID = saved.currentID,
                      let index = queue.order.firstIndex(where: {
                          queue.tracks.indices.contains($0) && queue.tracks[$0].id == currentID
                      }) {
                queue.position = index
                isSameTrack = true
            }
        }
        queue.position = min(max(queue.position, 0), max(queue.order.count - 1, 0))
        queue.listID = list.id
        writtenListID = list.id

        return QueueSnapshot(
            queue: queue,
            // Seconds into a track only mean something for the track they were saved for.
            positionSeconds: isSameTrack ? saved?.positionSeconds ?? 0 : 0,
            savedAt: saved?.savedAt ?? .distantPast
        )
    }

    private func loadLegacy() -> QueueSnapshot? {
        guard let legacyURL, let data = try? Data(contentsOf: legacyURL) else { return nil }
        return try? JSONDecoder().decode(QueueSnapshot.self, from: data)
    }

    func save(_ snapshot: QueueSnapshot) {
        let queue = snapshot.queue
        if queue.listID != writtenListID {
            let list = SavedList(
                id: queue.listID,
                tracks: queue.tracks,
                order: queue.order,
                isShuffled: queue.isShuffled,
                sourceDescription: queue.sourceDescription,
                lastAddedTrackIndex: queue.lastAddedTrackIndex,
                station: queue.station
            )
            // Atomic: a crash mid-write must not leave a half-written queue.
            guard let data = try? JSONEncoder().encode(list),
                  (try? data.write(to: listURL, options: .atomic)) != nil
            else { return }
            writtenListID = queue.listID
        }

        let position = SavedPosition(
            listID: queue.listID,
            position: queue.position,
            currentID: queue.current?.id,
            repeatMode: queue.repeatMode,
            positionSeconds: snapshot.positionSeconds,
            savedAt: snapshot.savedAt
        )
        guard let data = try? JSONEncoder().encode(position),
              (try? data.write(to: positionURL, options: .atomic)) != nil
        else { return }

        if let legacyURL { try? FileManager.default.removeItem(at: legacyURL) }
    }

    func clear() {
        for url in [listURL, positionURL] + (legacyURL.map { [$0] } ?? []) {
            try? FileManager.default.removeItem(at: url)
        }
        writtenListID = nil
    }
}
