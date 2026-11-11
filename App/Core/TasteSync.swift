import Foundation

/// The phone and the desktop learning together: each device's plays and skips, shared
/// through the sonic service on the server.
///
/// Every device kept its own play log and its own skips, and the mixes, radio, shuffle
/// and stats read only those, so a song skipped twice on the desktop was still served on
/// the phone. Now each device sends what it recorded and takes in what the others did.
/// Records keep their own ids, so the same one arriving twice is recognised, and sending
/// looks from a day before the last send, so nothing is missed at the edges -- a play is
/// stamped with when it started, which can be before a send it is recorded after. Of
/// those, only the ones the server does not have yet go: every record sent or taken in is
/// remembered by id for as long as the look-back can reach it. Before, the whole last day
/// went again on every foreground ("sent 71 plays and 15 skips" each time), the other
/// devices' plays included, sent back to the server they came from.
@MainActor
final class TasteSync {
    private enum Key {
        static let device = "taste.device"
        static let seq = "taste.seq"
        static let pushed = "taste.pushedThrough"
        /// Ids the server has, sent or taken in, to when each happened (seconds since 1970).
        static let known = "taste.knownIDs"
    }

    /// This install's own name on the server.
    let device: String
    private weak var appState: AppState?
    private var isSyncing = false
    private var timer: Task<Void, Never>?

    init() {
        let defaults = UserDefaults.standard
        if let saved = defaults.string(forKey: Key.device) {
            device = saved
        } else {
            device = UUID().uuidString
            defaults.set(device, forKey: Key.device)
        }
    }

    func attach(_ appState: AppState) {
        self.appState = appState
        // Besides launch and coming back: a desktop app stays open for days.
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15 * 60 * 1_000_000_000)
                await self?.sync()
            }
        }
    }

    func sync() async {
        guard let appState, !isSyncing, appState.reachability.network != .offline else { return }
        isSyncing = true
        defer { isSyncing = false }
        await appState.history.loaded()
        let client = SonicClient(configuration: appState.sonic.configuration)
        let defaults = UserDefaults.standard

        // Out: what this device recorded since a day before the last send, less what the
        // server already has.
        let started = Date.now
        let since = (defaults.object(forKey: Key.pushed) as? Date)?.addingTimeInterval(-86_400) ?? .distantPast
        // Values through NSNumber as well: Linux's defaults hand numbers back that way.
        var known = (defaults.dictionary(forKey: Key.known) ?? [:]).compactMapValues {
            ($0 as? Double) ?? ($0 as? NSNumber)?.doubleValue
        }
        let plays = appState.history.plays.filter { $0.at >= since }.map(Self.event).filter { known[$0.id] == nil }
        let skips = appState.skips.skips.filter { $0.at >= since }.map(Self.event).filter { known[$0.id] == nil }
        let outgoing = plays + skips
        do {
            for start in stride(from: 0, to: outgoing.count, by: 2_000) {
                try await client.pushTaste(device: device, events: Array(outgoing[start..<min(start + 2_000, outgoing.count)]))
            }
            defaults.set(started, forKey: Key.pushed)
            for event in outgoing { known[event.id] = event.at }
        } catch {
            await Diagnostics.shared.record("taste", "could not send \(outgoing.count): \(Diagnostics.describe(error))")
            return
        }

        // In: the other devices', a page at a time.
        var seq = defaults.integer(forKey: Key.seq)
        var newPlays: [ListeningHistory.Play] = []
        var newSkips: [SkipMemory.Skip] = []
        do {
            while true {
                let page = try await client.pullTaste(device: device, since: seq)
                for event in page.events {
                    known[event.id] = event.at
                    switch event.kind {
                    case "play": if let play = Self.play(event) { newPlays.append(play) }
                    case "skip": if let skip = Self.skip(event) { newSkips.append(skip) }
                    default: break
                    }
                }
                let advanced = page.seq > seq
                seq = page.seq
                if page.events.isEmpty || !advanced { break }
            }
        } catch {
            await Diagnostics.shared.record("taste", "could not read the other devices': \(Diagnostics.describe(error))")
        }
        let addedPlays = appState.history.merge(newPlays)
        let addedSkips = appState.skips.merge(newSkips)
        defaults.set(seq, forKey: Key.seq)
        // Only as far back as the next send can look: a day before this one, and a day of
        // slack for a clock that moved.
        let horizon = started.addingTimeInterval(-2 * 86_400).timeIntervalSince1970
        defaults.set(known.filter { $0.value >= horizon }, forKey: Key.known)
        if !outgoing.isEmpty || addedPlays + addedSkips > 0 {
            await Diagnostics.shared.record(
                "taste", "sent \(plays.count) plays and \(skips.count) skips; took in \(addedPlays) plays and \(addedSkips) skips from other devices"
            )
        }
    }

    // MARK: - Records to events and back

    private static func event(_ play: ListeningHistory.Play) -> SonicClient.TasteEvent {
        SonicClient.TasteEvent(
            id: play.id.uuidString, kind: "play", at: play.at.timeIntervalSince1970,
            songID: play.songID, title: play.title, artist: play.artist, album: play.album,
            genre: play.genre, duration: play.duration, position: nil,
            albumID: play.albumID, artistID: play.artistID, coverArt: play.coverArt
        )
    }

    private static func event(_ skip: SkipMemory.Skip) -> SonicClient.TasteEvent {
        SonicClient.TasteEvent(
            id: skip.id.uuidString, kind: "skip", at: skip.at.timeIntervalSince1970,
            songID: skip.songID, title: skip.title, artist: skip.artist, position: skip.position
        )
    }

    private static func play(_ event: SonicClient.TasteEvent) -> ListeningHistory.Play? {
        guard let id = UUID(uuidString: event.id) else { return nil }
        var play = ListeningHistory.Play(
            songID: event.songID, title: event.title, artist: event.artist,
            album: event.album ?? "Unknown Album", genre: event.genre, duration: event.duration ?? 0,
            at: Date(timeIntervalSince1970: event.at),
            albumID: event.albumID, artistID: event.artistID, coverArt: event.coverArt
        )
        play.id = id
        return play
    }

    private static func skip(_ event: SonicClient.TasteEvent) -> SkipMemory.Skip? {
        guard let id = UUID(uuidString: event.id) else { return nil }
        return SkipMemory.Skip(
            id: id, songID: event.songID, title: event.title, artist: event.artist,
            at: Date(timeIntervalSince1970: event.at), position: event.position ?? 0
        )
    }
}
