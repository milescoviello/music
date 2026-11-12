import Foundation
import Observation

/// Skips by hand early in a song, kept on this device and shared with the others through
/// `TasteSync`.
///
/// They are always counted, for the stats. Whether they also change what plays -- songs
/// skipped play less in the mixes, radio, Autoplay and shuffle, and two recent skips leave
/// one out for a while (`SkipMemory`) -- is a setting, off unless it is turned on.
///
/// Small, so read at launch and written whole, a few seconds after the last skip.
@MainActor
@Observable
final class SkipLog {
    @ObservationIgnored private(set) var skips: [SkipMemory.Skip] = []

    /// Songs skipped in `window`, beside the plays in Stats. A skip is kept apart from the
    /// plays on purpose -- a play is a song let run, the way the server counts one -- but
    /// it is still listening, and without a count it showed up nowhere.
    func count(in window: ListeningHistory.Window) -> Int {
        guard let start = window.start else { return skips.count }
        return skips.reduce(0) { $0 + ($1.at >= start ? 1 : 0) }
    }
    @ObservationIgnored private let url = Paths.root.appendingPathComponent("skips.json")
    /// A year of skipping at ten a day: they fade out of any score long before.
    @ObservationIgnored private let limit = 3_000
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var isLoaded = false
    /// The play log, whose full plays forgive earlier skips. Set by `AppState`.
    @ObservationIgnored weak var history: ListeningHistory?

    private static let shapesKey = "skips.shapeWhatPlays"

    /// Whether skips change what plays. Off by default: a skip is a mood more often than
    /// a verdict, and he would rather the mixes did not hold one against a song.
    var shapesWhatPlays: Bool {
        didSet {
            UserDefaults.standard.set(shapesWhatPlays, forKey: Self.shapesKey)
            SettingsLog.changed("Skips Shape What Plays", from: oldValue, to: shapesWhatPlays)
        }
    }

    init() {
        shapesWhatPlays = UserDefaults.standard.bool(forKey: Self.shapesKey)
        let url = url
        Task { [weak self] in
            let stored = await Task.detached(priority: .utility) { () -> [SkipMemory.Skip] in
                guard let data = try? Data(contentsOf: url) else { return [] }
                return ((try? JSONDecoder().decode([SkipMemory.Skip].self, from: data)) ?? []).map { skip in
                    var skip = skip
                    skip.at = StoredDate.repaired(skip.at)
                    return skip
                }
            }.value
            guard let self else { return }
            let recordedMeanwhile = !skips.isEmpty
            skips = stored + skips
            isLoaded = true
            if recordedMeanwhile { scheduleSave() }
        }
    }

    func record(_ song: Song, at position: Double) {
        skips.append(SkipMemory.Skip(
            songID: song.id, title: song.title, artist: song.artist ?? "", at: .now, position: position
        ))
        if skips.count > limit { skips.removeFirst(skips.count - limit) }
        var line = "“\(song.title)” (\(song.id)) skipped at \(LogReport.clock(position))"
        if shapesWhatPlays {
            line += avoided().contains(MixEngine.identity(song)) ? ": now left out of mixes and radio" : ": counts against it"
        }
        Task { await Diagnostics.shared.record("skips", line) }
        scheduleSave()
    }

    /// Skips another device recorded, each once. Returns how many were new.
    @discardableResult
    func merge(_ incoming: [SkipMemory.Skip]) -> Int {
        let known = Set(skips.map(\.id))
        let fresh = incoming.filter { !known.contains($0.id) }
        guard !fresh.isEmpty else { return 0 }
        skips = (skips + fresh).sorted { $0.at < $1.at }
        if skips.count > limit { skips.removeFirst(skips.count - limit) }
        scheduleSave()
        return fresh.count
    }

    /// The faded skips per recording, a full play since forgiving them. None while skips
    /// do not shape what plays, so nothing that reads them holds a skip against a song.
    func penalties(now: Date = .now) -> [String: Double] {
        guard shapesWhatPlays else { return [:] }
        let plays = (history?.plays ?? []).map { (identity: MixEngine.identity(title: $0.title, artist: $0.artist), at: $0.at) }
        return SkipMemory.penalties(skips: skips, plays: plays, now: now)
    }

    /// The recordings the mixes and radio leave out.
    func avoided(now: Date = .now) -> Set<String> {
        SkipMemory.avoided(penalties(now: now))
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, let self, isLoaded else { return }
            let snapshot = skips
            let url = url
            await Task.detached(priority: .utility) {
                guard let data = try? JSONEncoder().encode(snapshot) else { return }
                try? data.write(to: url, options: .atomic)
            }.value
        }
    }
}
