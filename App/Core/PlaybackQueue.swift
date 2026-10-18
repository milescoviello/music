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
    var tracks: [Song] = []
    /// A permutation of indices into `tracks`; the identity when unshuffled.
    var order: [Int] = []
    /// Index into `order`, not into `tracks`.
    var position: Int = 0
    var repeatMode: RepeatMode = .off
    var isShuffled: Bool = false
    /// "Kid A", "Freedom" -- shown in the player as the source of the queue.
    var sourceDescription: String = ""
    /// Index into `tracks` of the last song put in with Play Next or Add to Up Next:
    /// where the next Add to Up Next goes. Optional so a queue saved before it existed
    /// still decodes.
    var lastAddedTrackIndex: Int?
    /// Set when the queue is a station, which tops itself up as it plays.
    var station: Station?

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

/// What is written to disk: the queue plus where we were in the current track.
struct QueueSnapshot: Codable, Sendable {
    var queue: PlaybackQueue
    var positionSeconds: Double
    var savedAt: Date
}

/// Persists the queue so a relaunch resumes where you were.
actor PlaybackQueueStore {
    private let url: URL

    init(url: URL) {
        self.url = url
    }

    func load() -> QueueSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(QueueSnapshot.self, from: data)
    }

    func save(_ snapshot: QueueSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        // Atomic: a crash mid-write must not leave a half-written queue.
        try? data.write(to: url, options: .atomic)
    }

    func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}
