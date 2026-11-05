import Foundation
import Observation

/// Sends "please get me this album" to the Hermes agent, which acquires it over
/// Soulseek and puts it in the library.
///
/// The gateway authenticates with HMAC-SHA256 over `"<timestamp>.<body>"` and rejects
/// anything more than five minutes old — its V2 scheme. The older V1 signs the body
/// alone, which means a captured request replays forever, so this only ever sends V2.
///
/// The shared secret is entered on device and kept in the Keychain, never in the
/// repository: this repo is public, and a committed secret is a committed secret
/// whether or not the port is LAN-only.
@MainActor
@Observable
final class MusicRequestService {
    /// The configuration now lives on `HermesClient`, which owns the signing. Aliased so
    /// the Keychain helpers, and every item already written by them, keep working.
    typealias Configuration = HermesClient.Configuration

    /// One sent request, plus what has happened in the library since.
    ///
    /// The agent's own reply goes to its own channel and the app cannot read it. But it
    /// does not need to: the request is for *music*, and music appearing in the library
    /// is the answer. So each entry carries a snapshot of what the library already
    /// matched when it was sent, and anything beyond that snapshot is the arrival.
    struct Entry: Codable, Sendable, Identifiable {
        var id = UUID()
        var text: String
        var sentAt: Date
        var wasAccepted: Bool

        /// Every new field is optional so entries written by the previous build still
        /// decode -- a required field with a default does not save you here.
        var baseline: Baseline?
        var arrival: Arrival?
        var gaveUp: Bool?
        /// Correlation id for the results mailbox. Optional: entries written before the
        /// mailbox existed have none, and a default would stop them decoding at all.
        var requestID: UUID?

        /// Still worth checking on: accepted, nothing found yet, not timed out.
        var isWatching: Bool {
            wasAccepted && arrival == nil && gaveUp != true
        }
    }

    /// What the library already matched when the request went out.
    struct Baseline: Codable, Sendable, Equatable {
        var albumIDs: [String]
        var songCount: Int
        var takenAt: Date
    }

    struct Arrival: Codable, Sendable, Equatable {
        var at: Date
        var albumNames: [String]
        var songCount: Int
        /// So the row can navigate straight to it.
        var firstAlbumID: String?
    }

    /// A request that has not landed in a week is not going to.
    private let giveUpAfter: TimeInterval = 7 * 24 * 60 * 60

    private(set) var configuration: Configuration?
    private(set) var history: [Entry] = []
    private(set) var isSending = false
    var lastError: String?

    private let historyKey = "musicRequest.history"
    private weak var client: SubsonicClient?

    var isConfigured: Bool { configuration != nil }
    var isWatchingAnything: Bool { history.contains(where: \.isWatching) }

    func configure(client: SubsonicClient) {
        self.client = client
    }

    init() {
        configuration = Keychain.loadMusicRequestConfiguration()
        if let data = UserDefaults.standard.data(forKey: historyKey),
           let decoded = try? JSONDecoder().decode([Entry].self, from: data) {
            history = decoded
        }
    }

    func configure(endpoint: URL, secret: String, resultsBase: URL? = nil) {
        let configuration = Configuration(
            endpoint: endpoint, secret: secret, resultsBase: resultsBase
        )
        Keychain.saveMusicRequestConfiguration(configuration)
        self.configuration = configuration
        lastError = nil
    }

    func forget() {
        Keychain.clearMusicRequestConfiguration()
        configuration = nil
    }

    /// Returns true when the gateway accepted it. Acceptance means "queued for the
    /// agent", not "found" — this is a request, and the answer comes back through
    /// Hermes rather than here.
    @discardableResult
    func send(_ text: String) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let configuration else { return false }

        isSending = true
        lastError = nil
        defer { isSending = false }

        // Taken *before* the request is sent, so anything that shows up afterwards is
        // unambiguously new. Without it, "do I have Glass Harbor" would report itself
        // satisfied by the tracks that were already there.
        let baseline = await snapshot(for: trimmed)
        let requestID = UUID()

        let client = HermesClient(configuration: configuration)
        do {
            let acceptance = try await client.send(
                route: "music-request",
                requestID: requestID,
                fields: ["request": trimmed]
            )

            switch acceptance {
            case .accepted:
                record(Entry(
                    text: trimmed,
                    sentAt: .now,
                    wasAccepted: true,
                    baseline: baseline,
                    requestID: requestID
                ))
                return true

            case .duplicate:
                // The gateway answers 200 for this and does not run the agent, so it must
                // not be counted as sent.
                lastError = "That request was already sent moments ago."
                return false

            case let .rejected(status):
                lastError = status == 401
                    ? "The gateway rejected the signature — check the secret."
                    : "The gateway replied \(status)."
                record(Entry(
                    text: trimmed,
                    sentAt: .now,
                    wasAccepted: false,
                    baseline: baseline,
                    requestID: requestID
                ))
                return false
            }
        } catch {
            lastError = error.localizedDescription
            record(Entry(text: trimmed, sentAt: .now, wasAccepted: false, baseline: baseline))
            return false
        }
    }

    // MARK: - Watching the library

    /// Checks every outstanding request once. Cheap when there is nothing to watch,
    /// which is the normal case.
    func refresh() async {
        guard client != nil else { return }

        for entry in history where entry.isWatching {
            // A snapshot may be missing because the app was offline when the request
            // went out. Adopt the first successful reading as the baseline rather than
            // treating everything already in the library as an arrival.
            guard let current = await snapshot(for: entry.text) else { continue }

            // Found again by id after the wait, not kept as an index: a request sent while
            // this one was being checked goes in at the top, every index moves down one,
            // and the answer was written onto the request next to it.
            guard let index = history.firstIndex(where: { $0.id == entry.id }) else { continue }

            guard let baseline = entry.baseline else {
                history[index].baseline = current
                continue
            }

            let known = Set(baseline.albumIDs)
            let newAlbumIDs = current.albumIDs.filter { !known.contains($0) }

            if !newAlbumIDs.isEmpty || current.songCount > baseline.songCount {
                // Another wait, so the entry is found again after it as well.
                let names = await albumNames(for: newAlbumIDs)
                guard let index = history.firstIndex(where: { $0.id == entry.id }) else { continue }
                history[index].arrival = Arrival(
                    at: .now,
                    albumNames: names,
                    songCount: max(current.songCount - baseline.songCount, 0),
                    firstAlbumID: newAlbumIDs.first
                )
            } else if Date.now.timeIntervalSince(entry.sentAt) > giveUpAfter {
                history[index].gaveUp = true
            }
        }

        persistHistory()
    }

    /// What the library currently matches for a request string.
    private func snapshot(for text: String) async -> Baseline? {
        guard let client else { return nil }
        guard let results = try? await client.search(
            query: Self.searchTerms(from: text),
            artistCount: 0,
            albumCount: 50,
            songCount: 100,
            scope: .all
        ) else { return nil }

        return Baseline(
            albumIDs: results.albums.map(\.id).sorted(),
            songCount: results.songs.count,
            takenAt: .now
        )
    }

    private func albumNames(for ids: [String]) async -> [String] {
        guard let client else { return [] }
        var names: [String] = []
        for id in ids.prefix(3) {
            if let detail = try? await client.albumDetail(id: id) {
                names.append(detail.name)
            }
        }
        return names
    }

    /// `search3` tokenises on whitespace, so the separators people type between artist
    /// and album ("The Lanterns - Glass Harbor") have to go or the query matches nothing.
    static func searchTerms(from text: String) -> String {
        let stripped = text.replacingOccurrences(
            of: "[\\-–—_/|:]+",
            with: " ",
            options: .regularExpression
        )
        return stripped
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    func clearHistory() {
        history = []
        UserDefaults.standard.removeObject(forKey: historyKey)
    }

    private func record(_ entry: Entry) {
        // Newest first, capped: this is a memory aid, not a log.
        history.insert(entry, at: 0)
        history = Array(history.prefix(30))
        persistHistory()
    }

    private func persistHistory() {
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: historyKey)
        }
    }
}
