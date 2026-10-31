import Foundation
import Observation

/// Asking Hermes a question and waiting for the answer.
///
/// `MusicRequestService` deliberately does not do this. An acquisition is answered by
/// *music appearing in the library*, which is why it watches the library rather than a
/// reply; these features are answered by text, which only exists in the results mailbox.
/// Same signing, same secret, same `HermesClient` — different definition of "done".
///
/// Waiting is polling, because the phone has nothing listening on any port and nothing
/// should. A missing file means the agent is still working: **404 is not a failure**, and
/// giving up is a timeout the caller chooses, since a written note takes a minute and a
/// built playlist can take twenty.
@MainActor
@Observable
final class HermesAsk {
    /// A vibe playlist that is still being built.
    ///
    /// Persisted, unlike the short asks: twenty minutes is longer than anyone stares at a
    /// screen, so this has to survive the app being backgrounded and relaunched.
    struct PendingVibe: Codable, Sendable, Identifiable {
        var id = UUID()
        var requestID: UUID
        var name: String
        var vibe: String
        var sentAt: Date
        var finishedAt: Date?
        var playlistID: String?
        var note: String?
        var failure: String?

        var isWaiting: Bool { finishedAt == nil }
    }

    private(set) var vibes: [PendingVibe] = []
    var lastError: String?

    /// A vibe that has not landed in twenty minutes is not going to. The agent has to
    /// query the library several times and then create the playlist, so this is generous
    /// on purpose — but not open-ended, or a dead route leaves a spinner forever.
    static let vibeTimeout: TimeInterval = 20 * 60

    private let storageKey = "hermes.vibes"
    private weak var requests: MusicRequestService?

    init() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([PendingVibe].self, from: data) {
            vibes = decoded
        }
    }

    func configure(requests: MusicRequestService) {
        self.requests = requests
    }

    /// Nil when Hermes has not been set up, or has no results address — the features that
    /// need an answer back are unavailable then, and the UI says so rather than failing
    /// at the point of use.
    var configuration: HermesClient.Configuration? {
        guard let configuration = requests?.configuration,
              configuration.resultsBase != nil
        else { return nil }
        return configuration
    }

    var isAvailable: Bool { configuration != nil }

    // MARK: - Short asks

    /// Sends, then polls until the answer lands or `timeout` passes.
    ///
    /// Returns `.pending` only on timeout, so a caller can say "still working" rather than
    /// "failed" — with an agent on the other end, those are genuinely different.
    func ask<T: HermesPayload>(
        route: String,
        fields: [String: String],
        as type: T.Type,
        timeout: TimeInterval,
        pollEvery: TimeInterval = 3
    ) async -> HermesOutcome<T> {
        guard let configuration else { return .failed("Hermes isn't set up for answers yet.") }

        let client = HermesClient(configuration: configuration)
        let requestID = UUID()

        do {
            switch try await client.send(route: route, requestID: requestID, fields: fields) {
            case .accepted:
                break
            case .duplicate:
                // Cannot happen with a fresh id, but it means the agent did not run, so it
                // must never be waited on.
                return .failed("Hermes had already seen that request.")
            case let .rejected(status):
                return .failed(status == 401
                    ? "The gateway rejected the signature — check the secret."
                    : "The gateway replied \(status).")
            }
        } catch {
            return .failed(error.localizedDescription)
        }

        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            try? await Task.sleep(for: .seconds(pollEvery))
            if Task.isCancelled { return .pending }

            let outcome = await client.outcome(for: requestID, as: type)
            if case .pending = outcome { continue }
            return outcome
        }
        return .pending
    }

    // MARK: - Vibe playlists

    /// Starts a playlist build. The name is decided here, not by the agent.
    @discardableResult
    func startVibe(name: String, vibe: String, trackCount: Int = 25) async -> Bool {
        guard let configuration else {
            lastError = "Set the results address in Settings first."
            return false
        }

        let requestID = UUID()
        let client = HermesClient(configuration: configuration)

        do {
            let acceptance = try await client.send(
                route: "music-vibe",
                requestID: requestID,
                fields: ["vibe": vibe, "name": name, "track_count": String(trackCount)]
            )
            guard case .accepted = acceptance else {
                lastError = "The gateway did not accept that."
                return false
            }
        } catch {
            lastError = error.localizedDescription
            return false
        }

        vibes.insert(
            PendingVibe(requestID: requestID, name: name, vibe: vibe, sentAt: .now),
            at: 0
        )
        vibes = Array(vibes.prefix(20))
        persist()
        lastError = nil
        return true
    }

    /// Checks every outstanding vibe once.
    ///
    /// Three tiers, in order of confidence: the results file, then a playlist on the server
    /// with exactly the dictated name, then that playlist's comment as the note. The middle
    /// tier is why the name is chosen up front — if the mailbox never gets written, the
    /// playlist *is* the answer, and it can only be recognised by name.
    func refreshVibes(playlists: [Playlist]) async {
        guard let configuration else { return }
        let client = HermesClient(configuration: configuration)

        for vibe in vibes where vibe.isWaiting {
            let outcome = await client.outcome(for: vibe.requestID, as: VibeResult.self)
            // Found again by id after the wait, not held as an index: a vibe asked for in
            // the meantime goes in at the top and shifts every index, and one removed
            // shortens the list -- an index held across the wait then crashed the app.
            guard let index = vibes.firstIndex(where: { $0.id == vibe.id }) else { continue }
            switch outcome {
            case let .ok(result):
                vibes[index].finishedAt = .now
                vibes[index].playlistID = result.playlistID
                vibes[index].note = result.note
                continue
            case let .failed(message):
                vibes[index].finishedAt = .now
                vibes[index].failure = message
                continue
            case .pending:
                break
            }

            if let match = playlists.first(where: {
                $0.name.compare(vibe.name, options: .caseInsensitive) == .orderedSame
            }) {
                vibes[index].finishedAt = .now
                vibes[index].playlistID = match.id
                vibes[index].note = match.comment
                continue
            }

            if Date.now.timeIntervalSince(vibe.sentAt) > Self.vibeTimeout {
                vibes[index].finishedAt = .now
                vibes[index].failure = "Hermes didn't finish this one."
            }
        }

        persist()
    }

    var isWatchingAnything: Bool { vibes.contains(where: \.isWaiting) }

    func dismissVibe(_ id: UUID) {
        vibes.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(vibes) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}
