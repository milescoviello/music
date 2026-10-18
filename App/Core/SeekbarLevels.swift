import Foundation
import Observation

/// What the seekbar draws for each track: its loudness, start to end, from our sonic
/// service when the service has it, and from the phone's own measurement otherwise.
///
/// The service has analysed every track Navidrome has, streamed or not, so it is asked
/// first; the phone can only measure a file it holds. Both are the same readings
/// (`TrackShape.levels`), so which one drew a track never shows.
///
/// What the service gives is kept in memory and in a small file per track in Caches, so
/// a track played again has its shape before it has started. A 404 — not analysed yet —
/// is asked again after a while, and a service that cannot be reached is left alone for
/// a couple of minutes rather than asked on every track change.
@MainActor
@Observable
final class SeekbarLevelsStore {
    /// From the service, by song. Observed, so the seekbar redraws when its track's arrive.
    private(set) var fetched: [String: [Float]] = [:]

    /// The phone's own measurement of a track, if it has one. Read inside
    /// `levels(for:)`, so a view drawing that also observes the store this reads.
    @ObservationIgnored var measured: @MainActor (String) -> [Float]? = { _ in nil }
    /// The service's levels for a song: nil for not analysed, an error for unreachable.
    @ObservationIgnored var fetch: @Sendable (String) async throws -> [Float]?
    @ObservationIgnored var now: () -> Date = Date.init

    @ObservationIgnored private let directory: URL
    /// Looked for on disk this session, found or not.
    @ObservationIgnored private var looked: Set<String> = []
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private var notAnalysed: [String: Date] = [:]
    @ObservationIgnored private var unreachableUntil: Date?

    /// The service analyses in the background, so a track it did not know may be known
    /// soon; not so soon that skipping back and forth asks every time.
    static let notAnalysedRetry: TimeInterval = 10 * 60
    static let unreachableRetry: TimeInterval = 2 * 60

    init(directory: URL = Paths.seekbarLevels, client: SonicClient = SonicClient(configuration: .default)) {
        self.directory = directory
        fetch = { songID in
            try await client.levels(songID: songID, points: TrackShape.levelPoints)?.levels
        }
    }

    /// For a view body: whatever is in memory, the service's first. Call `request` from
    /// a `.task` to go and get it.
    func levels(for songID: String) -> [Float]? {
        fetched[songID] ?? measured(songID)
    }

    /// Fetches what is not already here, each on a task of the store's own, so a view
    /// that moves on to another track does not cancel a fetch half done — the next time
    /// this track comes up, it is already here.
    func request(_ songIDs: [String]) {
        for songID in songIDs where fetched[songID] == nil {
            Task { await load(songID) }
        }
    }

    /// From disk, else from the service. Returns at once for a track already here, being
    /// fetched, or not due to be asked about again.
    func load(_ songID: String) async {
        guard fetched[songID] == nil else { return }
        if !looked.contains(songID) {
            looked.insert(songID)
            if let stored = read(songID) {
                fetched[songID] = stored
                return
            }
        }

        let time = now()
        guard !inFlight.contains(songID),
              unreachableUntil.map({ time >= $0 }) ?? true,
              notAnalysed[songID].map({ time.timeIntervalSince($0) >= Self.notAnalysedRetry }) ?? true
        else { return }

        inFlight.insert(songID)
        defer { inFlight.remove(songID) }
        do {
            guard let levels = try await fetch(songID), !levels.isEmpty else {
                notAnalysed[songID] = now()
                return
            }
            unreachableUntil = nil
            notAnalysed[songID] = nil
            fetched[songID] = levels
            write(levels, for: songID)
        } catch {
            unreachableUntil = now().addingTimeInterval(Self.unreachableRetry)
        }
    }

    private func read(_ songID: String) -> [Float]? {
        guard let data = try? Data(contentsOf: file(for: songID)),
              let levels = try? JSONDecoder().decode([Float].self, from: data),
              !levels.isEmpty
        else { return nil }
        return levels
    }

    private func write(_ levels: [Float], for songID: String) {
        guard let data = try? JSONEncoder().encode(levels) else { return }
        try? data.write(to: file(for: songID), options: .atomic)
    }

    private func file(for songID: String) -> URL {
        let safe = songID.replacingOccurrences(of: "/", with: "_")
        return directory.appendingPathComponent("\(safe).json")
    }
}
