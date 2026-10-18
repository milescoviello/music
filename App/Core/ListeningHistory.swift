import Foundation
import Observation

/// Every play this phone has counted, kept locally.
///
/// The server knows *how many* times a track has been played, but not **when** — Subsonic
/// exposes a `playCount` and nothing else. So "top artists this month", "minutes listened
/// this week" and anything shaped like a recap cannot be asked for; they have to be
/// recorded as they happen.
///
/// Written at the same moment a scrobble is counted, so the local history and the
/// server's counts can never disagree about what happened, only about how far back they
/// can see.
@MainActor
@Observable
final class ListeningHistory {
    struct Play: Codable, Sendable, Identifiable {
        var id = UUID()
        let songID: String
        let title: String
        let artist: String
        let album: String
        let genre: String?
        /// Seconds, so totals do not need the library to answer.
        let duration: Int
        let at: Date
        // Recorded since the charts arrived, so a charted album or artist can be opened.
        // Optional, so the history written before them still decodes.
        var albumID: String?
        var artistID: String?
        var coverArt: String?

        var chartPlay: ChartPlay {
            ChartPlay(
                songID: songID, title: title, artist: artist, album: album,
                albumID: albumID, artistID: artistID, coverArt: coverArt, at: at
            )
        }
    }

    private(set) var plays: [Play] = []

    /// Roughly two years of heavy listening. Capped because this is read whole for every
    /// statistic, and an unbounded array would eventually make the stats screen crawl.
    private let limit = 20_000
    private let url = Paths.root.appendingPathComponent("history.json")
    private var saveTask: Task<Void, Never>?
    private let writer = HistoryWriter()
    /// Counts saves, so the writer can tell an older one that arrives late from the newest.
    @ObservationIgnored private var generation = 0

    init() {
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([Play].self, from: data) {
            plays = decoded
        }
    }

    func record(_ song: Song, at date: Date) {
        plays.append(Play(
            songID: song.id,
            title: song.title,
            artist: song.artist ?? "Unknown Artist",
            album: song.album ?? "Unknown Album",
            genre: song.genre,
            duration: song.duration ?? 0,
            at: date,
            albumID: song.albumId,
            artistID: song.primaryArtistID,
            coverArt: song.coverArt
        ))
        if plays.count > limit {
            plays.removeFirst(plays.count - limit)
        }
        scheduleSave()
    }

    func clear() {
        plays = []
        saveTask?.cancel()
        saveTask = nil
        // Through the writer, so a save already on its way cannot put the file back.
        generation += 1
        let cleared = generation
        Task { [writer, url] in await writer.remove(url, generation: cleared) }
    }

    /// Debounced, because `save()` encodes the **entire** log.
    ///
    /// At the 20,000-entry cap that is a multi-megabyte encode and an atomic write, and it
    /// was running at every track boundary -- precisely when the player is also
    /// rebuilding its output window. Same idiom as `PlaybackController.persist()`:
    /// coalesce the writes, and force one when the app goes to the background, which is
    /// the only moment the process may not come back.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        save()
    }

    /// Off the main actor, like the queue's own save: debouncing made the encode rare, but
    /// at the cap it still froze the screen for a noticeable moment once a track, five
    /// seconds after each boundary.
    private func save() {
        generation += 1
        let snapshot = plays
        let saved = generation
        Task { [writer, url] in await writer.write(snapshot, to: url, generation: saved) }
    }

    // MARK: - Statistics

    enum Window: String, CaseIterable, Identifiable {
        case week, month, year, all

        var id: String { rawValue }

        var title: String {
            switch self {
            case .week: return "Week"
            case .month: return "Month"
            case .year: return "Year"
            case .all: return "All Time"
            }
        }

        var start: Date? {
            let calendar = Calendar.current
            switch self {
            case .week: return calendar.date(byAdding: .day, value: -7, to: .now)
            case .month: return calendar.date(byAdding: .month, value: -1, to: .now)
            case .year: return calendar.date(byAdding: .year, value: -1, to: .now)
            case .all: return nil
            }
        }
    }

    func plays(in window: Window) -> [Play] {
        guard let start = window.start else { return plays }
        return plays.filter { $0.at >= start }
    }

    struct Ranked: Identifiable, Sendable {
        let name: String
        let count: Int
        let seconds: Int
        /// Carried so a row can show art without another lookup.
        let subtitle: String?
        var id: String { name }
    }

    func topArtists(in window: Window, limit: Int = 10) -> [Ranked] {
        rank(plays(in: window), by: \.artist, limit: limit) { _ in nil }
    }

    func topAlbums(in window: Window, limit: Int = 10) -> [Ranked] {
        let scoped = plays(in: window)
        var artistByAlbum: [String: String] = [:]
        for play in scoped { artistByAlbum[play.album] = play.artist }
        return rank(scoped, by: \.album, limit: limit) { artistByAlbum[$0] }
    }

    func topSongs(in window: Window, limit: Int = 10) -> [Ranked] {
        let scoped = plays(in: window)
        var artistBySong: [String: String] = [:]
        for play in scoped { artistBySong[play.title] = play.artist }
        return rank(scoped, by: \.title, limit: limit) { artistBySong[$0] }
    }

    func topGenres(in window: Window, limit: Int = 6) -> [Ranked] {
        let scoped = plays(in: window).filter { ($0.genre?.isEmpty == false) }
        return rank(scoped, by: { $0.genre ?? "" }, limit: limit) { _ in nil }
    }

    private func rank(
        _ source: [Play],
        by key: (Play) -> String,
        limit: Int,
        subtitle: (String) -> String?
    ) -> [Ranked] {
        var counts: [String: (count: Int, seconds: Int)] = [:]
        for play in source {
            let name = key(play)
            guard !name.isEmpty else { continue }
            var entry = counts[name] ?? (0, 0)
            entry.count += 1
            entry.seconds += play.duration
            counts[name] = entry
        }

        return counts
            .map { Ranked(name: $0.key, count: $0.value.count, seconds: $0.value.seconds, subtitle: subtitle($0.key)) }
            // Ties broken by name so the list does not reshuffle between renders.
            .sorted { ($0.count, $1.name) > ($1.count, $0.name) }
            .prefix(limit)
            .map { $0 }
    }

    func totalSeconds(in window: Window) -> Int {
        plays(in: window).reduce(0) { $0 + $1.duration }
    }

    /// Plays per hour of day, 0-23. The shape of this is the most personal thing in the
    /// whole screen: it says whether someone is a morning listener or a 2 a.m. one.
    func playsByHour(in window: Window) -> [Int] {
        var buckets = [Int](repeating: 0, count: 24)
        let calendar = Calendar.current
        for play in plays(in: window) {
            buckets[calendar.component(.hour, from: play.at)] += 1
        }
        return buckets
    }

    /// Plays per day for the last `days` days, oldest first, for the little bar chart.
    func playsByDay(_ days: Int = 30) -> [(date: Date, count: Int)] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        var buckets: [Date: Int] = [:]

        for play in plays {
            let day = calendar.startOfDay(for: play.at)
            guard let gap = calendar.dateComponents([.day], from: day, to: today).day,
                  gap >= 0, gap < days
            else { continue }
            buckets[day, default: 0] += 1
        }

        return (0..<days).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else {
                return nil
            }
            return (date: day, count: buckets[day] ?? 0)
        }
    }

    /// Consecutive days ending today (or yesterday) with at least one play.
    var streak: Int {
        let calendar = Calendar.current
        let days = Set(plays.map { calendar.startOfDay(for: $0.at) })
        guard !days.isEmpty else { return 0 }

        var cursor = calendar.startOfDay(for: .now)
        // Today not counting yet is normal at 9 a.m.; start from yesterday if so.
        if !days.contains(cursor) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: cursor),
                  days.contains(yesterday)
            else { return 0 }
            cursor = yesterday
        }

        var count = 0
        while days.contains(cursor) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return count
    }
}

/// Encodes and writes the history away from the main actor, one save at a time.
private actor HistoryWriter {
    /// The newest save written, or the clear that replaced it.
    private var written = 0

    func write(_ plays: [ListeningHistory.Play], to url: URL, generation: Int) {
        // Tasks are not guaranteed to arrive in the order they were made, and an older
        // snapshot must never overwrite a newer one.
        guard generation > written else { return }
        written = generation
        guard let data = try? JSONEncoder().encode(plays) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func remove(_ url: URL, generation: Int) {
        guard generation > written else { return }
        written = generation
        try? FileManager.default.removeItem(at: url)
    }
}
