import Foundation

/// Everything owed to the server that has not reached it yet.
///
/// The point of this app is that listening offline still counts — the same history, the
/// same play counts, the same stars as the desktop client. So a mutation that fails is
/// not dropped; it waits on disk.
///
/// **One file per mutation**, not one array in one file. An array means
/// read-modify-write, and two concurrent flushes or a kill mid-write can lose a whole
/// batch. A file per mutation makes each independently durable and independently
/// deletable, and the directory listing *is* the queue.
actor ServerOutbox {
    /// What kind of thing is owed. Scrobbles carry the original listen time; the others
/// are idempotent, so replaying one late is harmless.
    enum Kind: String, Codable, Sendable {
        case scrobble
        case star
        case unstar
        case rating
        /// A resume position for a long track. `positionMs` carries it.
        case bookmark
    }

    struct Pending: Codable, Sendable {
        /// **Optional, not defaulted.** A default does not make a key optional to
        /// decode: Swift's synthesized `init(from:)` calls `decode(_:forKey:)` for any
        /// non-optional property and throws when the key is absent, whatever default is
        /// written here. This field was added after the outbox already existed, so with
        /// a default every file written by the scrobble-only version failed to decode --
        /// and `flush` deletes files it cannot decode, silently discarding plays that
        /// were owed. Optional is the only shape that actually migrates.
        private var kind_: Kind?
        let songID: String
        /// When it happened, which is what gets submitted for a scrobble — not now.
        let listenedAt: Date
        /// `star`/`unstar` target kind: song, album or artist.
        var target: String?
        /// `rating` only.
        var rating: Int?
        /// `bookmark` only: milliseconds into the track. Optional for the same reason
        /// everything else here is — files written before bookmarks existed have no such
        /// key, and `flush` deletes what it cannot decode.
        var positionMs: Int?
        /// `scrobble` only: an earlier send got no answer -- a timeout, a dropped
        /// connection -- so the server may already have counted it. Optional like the rest.
        var unconfirmed: Bool?
        /// Same reasoning as `kind_`, though this one has been present since the start.
        private var attempts_: Int?

        /// A file with no `kind` predates the field, and everything back then was a play.
        var kind: Kind { kind_ ?? .scrobble }
        var attempts: Int {
            get { attempts_ ?? 0 }
            set { attempts_ = newValue }
        }

        enum CodingKeys: String, CodingKey {
            case kind_ = "kind"
            case songID
            case listenedAt
            case target
            case rating
            case positionMs
            case unconfirmed
            case attempts_ = "attempts"
        }

        init(
            kind: Kind = .scrobble,
            songID: String,
            listenedAt: Date,
            target: String? = nil,
            rating: Int? = nil,
            positionMs: Int? = nil,
            unconfirmed: Bool? = nil
        ) {
            kind_ = kind
            self.songID = songID
            self.listenedAt = listenedAt
            self.target = target
            self.rating = rating
            self.positionMs = positionMs
            self.unconfirmed = unconfirmed
            attempts_ = 0
        }
    }

    private let directory: URL
    /// A flush is under way; see `flush`.
    private var isFlushing = false
    /// Given up on. 30 days of retries is generous, and a permanently-rejected id — a
    /// track deleted from the server — must not be retried forever.
    private let maximumAttempts = 40

    init(directory: URL = Paths.outbox) {
        self.directory = directory
    }

    var count: Int {
        files().count
    }

    /// Counts by kind, for the diagnostics row.
    func summary() -> [Kind: Int] {
        var result: [Kind: Int] = [:]
        for file in files() {
            guard let data = try? Data(contentsOf: file),
                  let pending = try? JSONDecoder().decode(Pending.self, from: data)
            else { continue }
            result[pending.kind, default: 0] += 1
        }
        return result
    }

    /// `unconfirmed`: the play was sent and no answer came back, so it may be on the
    /// server already.
    func enqueue(songID: String, listenedAt: Date, unconfirmed: Bool = false) {
        write(Pending(
            kind: .scrobble, songID: songID, listenedAt: listenedAt, unconfirmed: unconfirmed ? true : nil
        ))
    }

    func enqueueStar(id: String, target: String, starred: Bool) {
        // Each of these replaces whatever is still waiting for the same thing. Left side by
        // side, two made in one second -- a star and the unstar straight after it -- went
        // out in the order of their file names' random part, and half the time the server
        // ended up with the one taken back.
        discard(id: id, kinds: [.star, .unstar])
        write(Pending(
            kind: starred ? .star : .unstar,
            songID: id,
            listenedAt: .now,
            target: target
        ))
    }

    func enqueueRating(id: String, rating: Int) {
        discard(id: id, kinds: [.rating])
        write(Pending(kind: .rating, songID: id, listenedAt: .now, rating: rating))
    }

    /// A resume position that could not be saved now. `nil` position means "forget where
    /// I was", which is what finishing a track does.
    func enqueueBookmark(id: String, positionMilliseconds: Int?) {
        discard(id: id, kinds: [.bookmark])
        write(Pending(
            kind: .bookmark, songID: id, listenedAt: .now, positionMs: positionMilliseconds
        ))
    }

    /// Drops what is still waiting for `id` of these kinds, because a newer change to the
    /// same thing has just reached the server. Replayed later, the older one would undo
    /// it: starred offline, unstarred once back online, and the next flush starred it
    /// again.
    func discard(id: String, kinds: Set<Kind>) {
        for file in files() {
            guard let data = try? Data(contentsOf: file),
                  let pending = try? JSONDecoder().decode(Pending.self, from: data),
                  pending.songID == id, kinds.contains(pending.kind)
            else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func write(_ pending: Pending) {
        // The filename carries the timestamp so a plain name sort is chronological --
        // zero-padded, because otherwise the sort breaks the day the epoch gains a
        // digit -- plus a uuid, so two writes in one second cannot collide.
        let stamp = String(format: "%012d", Int(pending.listenedAt.timeIntervalSince1970))
        let name = "\(stamp)-\(UUID().uuidString).json"
        guard let data = try? JSONEncoder().encode(pending) else { return }
        try? data.write(to: directory.appendingPathComponent(name), options: .atomic)
        let note = pending.unconfirmed == true ? ", sent once but unanswered" : ""
        let message = "waiting to send: \(pending.kind.rawValue) of \(pending.songID)\(note)"
        Task { await Diagnostics.shared.record("outbox", message) }
    }

    /// Submits everything, oldest first, and stops at the first network failure — there
    /// is no point hammering a server that is not reachable, and order is worth
    /// preserving in the history.
    func flush(using client: SubsonicClient) async -> Int {
        // An actor runs another call while this one awaits the network, so two flushes
        // started together -- launch and the network coming back -- each read the same
        // files and sent them both: every owed play counted twice.
        guard !isFlushing else { return 0 }
        isFlushing = true
        defer { isFlushing = false }

        var sent = 0

        for file in files() {
            guard let data = try? Data(contentsOf: file),
                  var pending = try? JSONDecoder().decode(Pending.self, from: data)
            else {
                // Undecodable: delete it rather than block the queue behind it.
                try? FileManager.default.removeItem(at: file)
                continue
            }

            do {
                if pending.unconfirmed == true, try await isOnServer(pending, using: client) {
                    // The first send arrived and only its answer was lost. Sent again, the
                    // server would count the play twice: it can't tell a repeat.
                    await Diagnostics.shared.record("outbox", "\(pending.kind.rawValue) of \(pending.songID) was on the server already; not sent again")
                } else {
                    try await submit(pending, using: client)
                }
                try? FileManager.default.removeItem(at: file)
                sent += 1
            } catch {
                pending.attempts += 1
                if pending.kind == .scrobble, (error as? SubsonicClient.ClientError)?.isUnanswered == true {
                    pending.unconfirmed = true
                }
                if pending.attempts >= maximumAttempts {
                    // Lost for good, so it must be on record.
                    await Diagnostics.shared.record(
                        "outbox",
                        "gave up on \(pending.kind.rawValue) of \(pending.songID) after \(pending.attempts) tries: \(Diagnostics.describe(error))"
                    )
                    try? FileManager.default.removeItem(at: file)
                } else if let updated = try? JSONEncoder().encode(pending) {
                    try? updated.write(to: file, options: .atomic)
                }
                // Refused rather than unreachable -- a scrobble for a track since deleted.
                // It must not hold up everything behind it, which it did for up to 40
                // flushes: the server is there, so carry on.
                if case SubsonicClient.ClientError.rejected = error { continue }
                break
            }
        }

        if sent > 0 {
            await Diagnostics.shared.record("outbox", "sent \(sent) that were waiting")
        }
        return sent
    }

    /// Whether the server already has this play. A scrobble sets the song's last-played
    /// time to the time it carries, so a match means it arrived. A later play of the same
    /// song since leaves it unknown, and it is sent: a rare double count rather than a
    /// lost play.
    private func isOnServer(_ pending: Pending, using client: SubsonicClient) async throws -> Bool {
        guard pending.kind == .scrobble,
              let played = try await client.song(id: pending.songID).lastPlayedAt
        else { return false }
        return abs(played.timeIntervalSince(pending.listenedAt)) < 2
    }

    private func submit(_ pending: Pending, using client: SubsonicClient) async throws {
        switch pending.kind {
        case .scrobble:
            try await client.scrobble(
                id: pending.songID,
                submission: true,
                at: pending.listenedAt
            )
        case .star:
            try await client.star(id: pending.songID, kind: starKind(pending.target))
        case .unstar:
            try await client.unstar(id: pending.songID, kind: starKind(pending.target))
        case .rating:
            try await client.setRating(id: pending.songID, rating: pending.rating ?? 0)
        case .bookmark:
            if let position = pending.positionMs {
                try await client.createBookmark(id: pending.songID, positionMilliseconds: position)
            } else {
                try await client.deleteBookmark(id: pending.songID)
            }
        }
    }

    private func starKind(_ raw: String?) -> SubsonicClient.StarKind {
        switch raw {
        case "album": return .album
        case "artist": return .artist
        default: return .song
        }
    }

    private func files() -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        return contents
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
