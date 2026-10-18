import Foundation

/// The beats of the tracks about to be faded, from our sonic service, for beat-matched
/// fades.
///
/// Asked for only while Beat-Matched Fades is on, and only for the tracks around what is
/// playing, so it is held in memory and no more: a few hundred beats a track, for the
/// last couple of dozen tracks. A 404 — not analysed yet — is asked again after a while,
/// and a service that cannot be reached is left alone for a couple of minutes, the same
/// as the seekbar's levels; either way the fade is an ordinary Sweet Fade meanwhile.
@MainActor
final class RhythmStore {
    /// The service's rhythm for a song: nil for not analysed, an error for unreachable.
    var fetch: @Sendable (String) async throws -> SonicClient.Rhythm?
    var now: () -> Date = Date.init

    private var known: [String: SonicClient.Rhythm] = [:]
    /// Oldest first, so the store can let go of what is long past.
    private var arrived: [String] = []
    private var inFlight: Set<String> = []
    private var notAnalysed: [String: Date] = [:]
    private var unreachableUntil: Date?

    static let notAnalysedRetry: TimeInterval = 10 * 60
    static let unreachableRetry: TimeInterval = 2 * 60
    /// The window is three tracks; this is enough to come back to the last few queues.
    static let capacity = 24

    init(client: SonicClient = SonicClient(configuration: .default)) {
        fetch = { songID in try await client.rhythm(songID: songID) }
    }

    func rhythm(for songID: String) -> SonicClient.Rhythm? {
        known[songID]
    }

    /// Fetches what is not already here, each on a task of the store's own, and tells
    /// `onLoaded` about each that arrives — so the transitions either side of it can be
    /// planned again.
    func request(_ songIDs: [String], onLoaded: @escaping @MainActor (String) -> Void) {
        for songID in songIDs where known[songID] == nil {
            Task {
                if await load(songID) { onLoaded(songID) }
            }
        }
    }

    /// True when this call brought the song's rhythm in. Returns at once for a song
    /// already here, being fetched, or not due to be asked about again.
    @discardableResult
    func load(_ songID: String) async -> Bool {
        let time = now()
        guard known[songID] == nil,
              !inFlight.contains(songID),
              unreachableUntil.map({ time >= $0 }) ?? true,
              notAnalysed[songID].map({ time.timeIntervalSince($0) >= Self.notAnalysedRetry }) ?? true
        else { return false }

        inFlight.insert(songID)
        defer { inFlight.remove(songID) }
        do {
            guard let rhythm = try await fetch(songID) else {
                notAnalysed[songID] = now()
                return false
            }
            unreachableUntil = nil
            notAnalysed[songID] = nil
            known[songID] = rhythm
            arrived.append(songID)
            if arrived.count > Self.capacity {
                known[arrived.removeFirst()] = nil
            }
            return true
        } catch {
            unreachableUntil = now().addingTimeInterval(Self.unreachableRetry)
            return false
        }
    }
}
