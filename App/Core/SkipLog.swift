import Foundation

/// The skips `SkipMemory` reads, kept on this device: the server never hears of them.
///
/// Small, so read at launch and written whole, a few seconds after the last skip.
@MainActor
final class SkipLog {
    private(set) var skips: [SkipMemory.Skip] = []
    private let url = Paths.root.appendingPathComponent("skips.json")
    /// A year of skipping at ten a day: they fade out of any score long before.
    private let limit = 3_000
    private var saveTask: Task<Void, Never>?
    private var isLoaded = false
    /// The play log, whose full plays forgive earlier skips. Set by `AppState`.
    weak var history: ListeningHistory?

    init() {
        let url = url
        Task { [weak self] in
            let stored = await Task.detached(priority: .utility) { () -> [SkipMemory.Skip] in
                guard let data = try? Data(contentsOf: url) else { return [] }
                return (try? JSONDecoder().decode([SkipMemory.Skip].self, from: data)) ?? []
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
        let left = avoided().contains(MixEngine.identity(song))
        let line = "“\(song.title)” (\(song.id)) skipped at \(LogReport.clock(position)): \(left ? "now left out of mixes and radio" : "counts against it")"
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

    /// The faded skips per recording, a full play since forgiving them.
    func penalties(now: Date = .now) -> [String: Double] {
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
