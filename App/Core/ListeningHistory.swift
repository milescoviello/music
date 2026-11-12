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
        /// `var` for `relink`: the server gives a song a new id when its file moves.
        var songID: String
        /// `var`, like the album, for a song linked by hand to a copy under another name.
        var title: String
        var artist: String
        var album: String
        /// `var` for `regenre`: the genre the play was counted under, from the tags of the day.
        var genre: String?
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
    /// Counts `relink`s that changed something, for what was worked out from the plays
    /// before: Home's month chart, built at launch, still showed the old ids until the
    /// next one.
    private(set) var relinked = 0

    /// Roughly two years of heavy listening. Capped because this is read whole for every
    /// statistic, and an unbounded array would eventually make the stats screen crawl.
    private let limit = 20_000
    private let url = Paths.root.appendingPathComponent("history.json")
    private var saveTask: Task<Void, Never>?
    private let writer = HistoryWriter()
    /// Counts saves, so the writer can tell an older one that arrives late from the newest.
    @ObservationIgnored private var generation = 0

    /// The log on disk being read. Until it finishes, `plays` holds only what has been
    /// recorded since launch, and nothing is saved, because saving then would write a
    /// log with the history missing.
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private var isLoaded = false
    @ObservationIgnored private var savesWhenLoaded = false
    /// Cleared before the log on disk had been read, so what is read is not kept.
    @ObservationIgnored private var discardsStored = false

    /// Read off the main actor. At the cap it is a multi-megabyte decode, and in here it
    /// ran on the main thread while the app was being built at launch, before anything
    /// was on screen.
    init() {
        loading = Task { [weak self] in await self?.load() }
    }

    /// Waits until the log on disk has been read, for anything that needs the whole of it
    /// at once. Views need not: `plays` is observed, and they redraw when it arrives.
    func loaded() async {
        await loading?.value
    }

    private func load() async {
        let url = url
        let stored = await Task.detached(priority: .userInitiated) { () -> [Play] in
            guard let data = try? Data(contentsOf: url) else { return [] }
            return (try? JSONDecoder().decode([Play].self, from: data)) ?? []
        }.value

        if !discardsStored {
            // Anything recorded while it was being read came after everything in it.
            plays = stored + plays
            if plays.count > limit {
                plays.removeFirst(plays.count - limit)
            }
        }
        isLoaded = true
        if savesWhenLoaded {
            savesWhenLoaded = false
            save()
        }
    }

    func record(_ song: Song, at date: Date) {
        plays.append(Play(
            songID: song.id,
            title: song.title,
            artist: song.artist ?? "Unknown Artist",
            album: song.album ?? "Unknown Album",
            genre: song.mainGenre,
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

    /// Plays another device recorded, from `TasteSync`: each once, by its id, in time
    /// order with the rest. Returns how many were new.
    @discardableResult
    func merge(_ incoming: [Play]) -> Int {
        let known = Set(plays.map(\.id))
        let fresh = incoming.filter { !known.contains($0.id) }
        guard !fresh.isEmpty else { return 0 }
        plays = (plays + fresh).sorted { $0.at < $1.at }
        if plays.count > limit {
            plays.removeFirst(plays.count - limit)
        }
        scheduleSave()
        return fresh.count
    }

    /// Points the plays of each song id in `links` at what the server calls it now: see
    /// `HistoryRepair`. Returns how many plays changed.
    @discardableResult
    func relink(_ links: [String: HistoryRepair.Link]) -> Int {
        guard !links.isEmpty else { return 0 }
        var changed = 0
        for index in plays.indices {
            guard let link = links[plays[index].songID] else { continue }
            var play = plays[index]
            play.songID = link.songID
            play.title = link.title
            play.artist = link.artist
            play.album = link.album
            play.albumID = link.albumID
            if let artistID = link.artistID { play.artistID = artistID }
            if let coverArt = link.coverArt { play.coverArt = coverArt }
            guard play.songID != plays[index].songID || play.title != plays[index].title
                || play.artist != plays[index].artist || play.album != plays[index].album
                || play.albumID != plays[index].albumID || play.artistID != plays[index].artistID
                || play.coverArt != plays[index].coverArt
            else { continue }
            plays[index] = play
            changed += 1
        }
        if changed > 0 {
            relinked += 1
            scheduleSave()
        }
        return changed
    }

    /// Gives each play of a song in `genres` that song's genre as the server tags it now,
    /// so the stats follow a retag instead of keeping what the tags said at play time.
    /// Returns how many plays changed.
    @discardableResult
    func regenre(_ genres: [String: String]) -> Int {
        guard !genres.isEmpty else { return 0 }
        var changed = 0
        for index in plays.indices {
            guard let genre = genres[plays[index].songID], genre != plays[index].genre else { continue }
            plays[index].genre = genre
            changed += 1
        }
        if changed > 0 { scheduleSave() }
        return changed
    }

    func clear() {
        plays = []
        if !isLoaded { discardsStored = true }
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
        guard isLoaded else {
            savesWhenLoaded = true
            return
        }
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
        /// What the plays were counted under: for an album or a song, its artist as well.
        var key: String
        var id: String { key }
    }

    func topArtists(in window: Window, limit: Int = 10) -> [Ranked] {
        rank(plays(in: window), name: \.artist, limit: limit)
    }

    /// Counted by album *and* artist. By name alone, every album called "Singles" or
    /// "Greatest Hits" -- this library has several of each -- was one entry with all their
    /// plays, shown under whichever artist was played last.
    func topAlbums(in window: Window, limit: Int = 10) -> [Ranked] {
        rank(plays(in: window), name: \.album, artist: \.artist, limit: limit)
    }

    /// By title and artist, for the same reason: two artists' songs of one title are two songs.
    func topSongs(in window: Window, limit: Int = 10) -> [Ranked] {
        rank(plays(in: window), name: \.title, artist: \.artist, limit: limit)
    }

    func topGenres(in window: Window, limit: Int = 6) -> [Ranked] {
        let scoped = plays(in: window).filter { ($0.genre?.isEmpty == false) }
        return rank(scoped, name: { $0.genre ?? "" }, limit: limit)
    }

    private func rank(
        _ source: [Play],
        name: (Play) -> String,
        artist: ((Play) -> String)? = nil,
        limit: Int
    ) -> [Ranked] {
        var counts: [String: (name: String, artist: String?, count: Int, seconds: Int)] = [:]
        for play in source {
            let title = name(play)
            guard !title.isEmpty else { continue }
            let by = artist?(play)
            let key = by.map { "\(title)\u{1F}\($0)" } ?? title
            var entry = counts[key] ?? (title, by, 0, 0)
            entry.count += 1
            entry.seconds += play.duration
            counts[key] = entry
        }

        return counts
            .map { Ranked(name: $0.value.name, count: $0.value.count, seconds: $0.value.seconds, subtitle: $0.value.artist, key: $0.key) }
            // Ties broken by name, then artist, so the list does not reshuffle between
            // renders -- two entries can share a name now.
            .sorted { a, b in
                a.count != b.count ? a.count > b.count : (a.name, a.subtitle ?? "") < (b.name, b.subtitle ?? "")
            }
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

// MARK: - The year in music

extension ListeningHistory {
    func recap(year: Int = Calendar.current.component(.year, from: .now), limit: Int = 10) -> Recap {
        Recap.make(plays.map {
            Recap.Play(songID: $0.songID, title: $0.title, artist: $0.artist, album: $0.album, albumID: $0.albumID,
                       coverArt: $0.coverArt, genre: $0.genre, duration: $0.duration, at: $0.at)
        }, year: year, limit: limit)
    }
}
