import Foundation
import Observation

/// Plexamp's Autoplay: when the queue is about to run out, what plays next.
///
/// A few seconds after the end of the queue changes, every choice that makes sense for
/// it is worked out *concretely* — not "Next Album" but the album itself, with its cover —
/// and shown as a carousel at the bottom of Up Next. The one selected is added when the
/// last track is nearly over, early enough to fade or run gaplessly into it.
///
/// The selection is remembered separately for a queue that ended with an album and one
/// that did not, as Plexamp does: after an album you usually want the next one, after a
/// playlist you do not.
@MainActor
@Observable
final class AutoplayService {
    struct Option: Identifiable, Sendable {
        let choice: AutoplayChoice
        let title: String
        let subtitle: String
        var coverArt: String?
        let plan: Plan

        var id: Int { choice.rawValue }
    }

    /// What to fetch when an option is chosen. Worked out with the option, so adding it
    /// is one request rather than the whole chain again.
    enum Plan: Sendable {
        case nothing
        case album(id: String)
        case artistMix(ArtistRef)
        case artistRadio(artistID: String, seed: Song)
        case trackRadio(Song)
        case similarArtists(seed: Song)
        case decade(start: Int)
        case library
    }

    private enum Key {
        static let enabled = "autoplay.enabled"
        static let albumChoice = "autoplay.albumChoice"
        static let otherChoice = "autoplay.otherChoice"
        static let albumDirection = "autoplay.albumDirection"
    }

    private(set) var options: [Option] = []
    private(set) var selected: AutoplayChoice?
    private(set) var endedWithAlbum = false
    private(set) var isAdding = false

    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Key.enabled)
            queueKey = nil
            queueChanged()
        }
    }

    /// Plexamp's Album Direction: after an album, offer the next one or the previous one.
    var albumDirection: AutoplayChoice {
        didSet {
            UserDefaults.standard.set(albumDirection.rawValue, forKey: Key.albumDirection)
            queueKey = nil
            queueChanged()
        }
    }

    @ObservationIgnored private weak var appState: AppState?
    @ObservationIgnored private var queueKey: String?
    @ObservationIgnored private var computeTask: Task<Void, Never>?
    @ObservationIgnored private var addTask: Task<Bool, Never>?

    init() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.object(forKey: Key.enabled) as? Bool ?? true
        albumDirection = (defaults.object(forKey: Key.albumDirection) as? Int)
            .flatMap(AutoplayChoice.init(rawValue:)) ?? .nextAlbum
    }

    func configure(appState: AppState) {
        self.appState = appState
    }

    /// Whether the carousel applies to the queue as it stands.
    var isActive: Bool {
        guard isEnabled, let player = appState?.player else { return false }
        return AutoplayRules.isActive(
            repeatMode: player.queue.repeatMode,
            upNextCount: player.queue.upNextCount,
            isSelfExtending: player.isSelfExtending
        )
    }

    var selectedOption: Option? {
        options.first { $0.choice == selected }
    }

    // MARK: - Choosing

    func select(_ choice: AutoplayChoice) {
        selected = choice
        UserDefaults.standard.set(choice.rawValue, forKey: endedWithAlbum ? Key.albumChoice : Key.otherChoice)
    }

    private func preferred(endedWithAlbum: Bool) -> AutoplayChoice {
        let stored = UserDefaults.standard.object(forKey: endedWithAlbum ? Key.albumChoice : Key.otherChoice) as? Int
        return stored.flatMap(AutoplayChoice.init(rawValue:))
            ?? AutoplayRules.defaultChoice(endedWithAlbum: endedWithAlbum, albumDirection: albumDirection)
    }

    // MARK: - Working out the options

    /// Called on every queue change. Cheap unless the end of the queue moved, and even
    /// then it waits three seconds — Plexamp's delay — so a run of edits costs one pass.
    func queueChanged() {
        guard isActive, let queue = appState?.player.queue else {
            computeTask?.cancel()
            options = []
            queueKey = nil
            return
        }

        let key = queue.order.suffix(2)
            .compactMap { queue.tracks.indices.contains($0) ? queue.tracks[$0].id : nil }
            .joined(separator: "-")
        guard key != queueKey else { return }
        queueKey = key
        options = []

        computeTask?.cancel()
        computeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await self?.compute()
        }
    }

    private func compute() async {
        guard let appState else { return }
        let queue = appState.player.queue
        guard let lastIndex = queue.order.last, queue.tracks.indices.contains(lastIndex) else { return }
        let last = queue.tracks[lastIndex]
        let client = appState.client
        let albumEnding = AutoplayRules.endsWithAlbum(queue)

        // The two lookups most options need, made once.
        var artist: ArtistDetail?
        var similar: [Artist] = []
        if let artistID = last.primaryArtistID {
            async let detail = client.artistDetail(id: artistID)
            async let info = client.artistInfo(id: artistID, similarCount: 10)
            artist = try? await detail
            similar = (try? await info)?.similarArtists ?? []
        }

        var built: [Option] = []
        for choice in AutoplayRules.choices(endedWithAlbum: albumEnding, albumDirection: albumDirection) {
            guard !Task.isCancelled else { return }
            if let option = await option(for: choice, last: last, artist: artist, similar: similar) {
                built.append(option)
            }
        }

        endedWithAlbum = albumEnding
        options = built
        selected = AutoplayRules.selection(
            preferred: preferred(endedWithAlbum: albumEnding),
            available: built.map(\.choice)
        )
    }

    private func option(for choice: AutoplayChoice, last: Song, artist: ArtistDetail?, similar: [Artist]) async -> Option? {
        let artistName = artist?.name ?? last.artist ?? "Artist"

        switch choice {
        case .silence:
            return Option(choice: choice, title: "Silence", subtitle: "The party is over.", plan: .nothing)

        case .nextAlbum, .previousAlbum:
            guard let albumID = last.albumId, let artist,
                  let album = AutoplayRules.neighbour(of: albumID, in: artist.album ?? [], direction: choice)
            else { return nil }
            return Option(choice: choice, title: album.name, subtitle: choice.title, coverArt: album.coverArt, plan: .album(id: album.id))

        case .similarAlbum:
            guard let appState else { return nil }
            // The sonically nearest album by someone else, when the analysis has it.
            if let albumID = last.albumId, let album = await appState.sonic.similarAlbums(to: albumID, limit: 1)?.first {
                return Option(
                    choice: choice, title: album.name, subtitle: "Similar Album · \(album.artist ?? "")",
                    coverArt: album.coverArt, plan: .album(id: album.id)
                )
            }
            for candidate in similar.prefix(3) {
                guard let detail = try? await appState.client.artistDetail(id: candidate.id),
                      let album = (detail.album ?? []).max(by: { ($0.playCount ?? 0) < ($1.playCount ?? 0) })
                else { continue }
                return Option(
                    choice: choice, title: album.name, subtitle: "Similar Album · \(detail.name)",
                    coverArt: album.coverArt, plan: .album(id: album.id)
                )
            }
            return nil

        case .artistMix:
            guard let id = last.primaryArtistID else { return nil }
            return Option(
                choice: choice, title: "\(artistName) Mix", subtitle: choice.title, coverArt: last.coverArt,
                plan: .artistMix(ArtistRef(id: id, name: artistName))
            )

        case .artistRadio:
            guard let id = last.primaryArtistID else { return nil }
            return Option(
                choice: choice, title: "\(artistName) Radio", subtitle: choice.title, coverArt: last.coverArt,
                plan: .artistRadio(artistID: id, seed: last)
            )

        case .trackRadio:
            return Option(choice: choice, title: "\(last.title) Radio", subtitle: choice.title, coverArt: last.coverArt, plan: .trackRadio(last))

        case .similarArtists:
            let names = similar.prefix(3).map(\.name)
            return Option(
                choice: choice, title: choice.title,
                subtitle: names.isEmpty ? "Like \(artistName)" : names.joined(separator: ", "),
                coverArt: similar.first?.coverArt, plan: .similarArtists(seed: last)
            )

        case .decade:
            guard let year = last.year, year > 0 else { return nil }
            let start = AutoplayRules.decadeStart(of: year)
            return Option(choice: choice, title: "The \(start)s", subtitle: choice.title, plan: .decade(start: start))

        case .libraryRadio:
            return Option(choice: choice, title: choice.title, subtitle: "Anything from your library", plan: .library)
        }
    }

    // MARK: - Adding

    /// Adds the selected option's tracks to the end of the queue. Returns whether anything
    /// was added; safe to call repeatedly, as the player does while the last track ends.
    @discardableResult
    func extend() async -> Bool {
        if let addTask { return await addTask.value }
        guard isActive, let option = selectedOption, option.choice != .silence, let appState else { return false }

        isAdding = true
        let task = Task { [weak self] () -> Bool in
            guard let self else { return false }
            let songs = await self.songs(for: option)
            let queued = Set(appState.player.queue.tracks.map(\.id))
            let fresh = songs.filter { !queued.contains($0.id) }.prefix(option.choice.trackCount)
            guard !fresh.isEmpty else { return false }
            appState.player.append(Array(fresh))
            return true
        }
        addTask = task
        let added = await task.value
        addTask = nil
        isAdding = false
        return added
    }

    private func songs(for option: Option) async -> [Song] {
        guard let appState else { return [] }
        let client = appState.client
        let scope = appState.scope.scope
        let radio = appState.radio
        let count = option.choice.trackCount

        switch option.plan {
        case .nothing:
            return []
        case let .album(id):
            return (try? await client.albumDetail(id: id))?.songs ?? []
        case let .artistMix(artist):
            return await radio.artistMix(artist, scope: scope, size: count)
        case let .artistRadio(artistID, seed):
            // The artist and those like them, mixed: Navidrome's similar songs for an
            // artist id come back empty, so this is assembled from both halves.
            async let own = client.artistSongs(id: artistID)
            async let like = client.similarSongs(toSongID: seed.id, count: count)
            let mine = ((try? await own) ?? []).shuffled().prefix(count / 3)
            let theirs = (try? await like) ?? []
            return Array((Array(mine) + theirs).shuffled().prefix(count))
        case let .trackRadio(seed):
            let queued = appState.player.queue.tracks.map(\.id)
            if let sonic = await appState.sonic.radio(seeds: [seed.id], excluding: queued, limit: count) {
                return sonic
            }
            return Array(await radio.mix(seed: seed, scope: scope, size: count + 1).dropFirst())
        case let .similarArtists(seed):
            // `getSimilarSongs2` is exactly this: tracks by artists similar to the seed's.
            let artist = seed.primaryArtistID
            let similar = (try? await client.similarSongs(toSongID: seed.id, count: count * 2)) ?? []
            let others = similar.filter { $0.primaryArtistID != artist }
            return Array((others.isEmpty ? similar : others).prefix(count))
        case let .decade(start):
            return (try? await client.randomSongs(size: count, fromYear: start, toYear: start + 9, scope: scope)) ?? []
        case .library:
            return (try? await client.randomSongs(size: count, scope: scope)) ?? []
        }
    }
}

/// Plexamp's Guest DJs, run against Navidrome. The rules — when to act, where to insert,
/// what to filter out — are `GuestDJRules`, which is tested; this does the fetching.
@MainActor
@Observable
final class GuestDJService {
    private enum Key {
        static let dj = "guestDJ.mode"
        static let generated = "guestDJ.generated"
        static let processed = "guestDJ.processed"
    }

    private(set) var dj: GuestDJ?
    /// The DJ's picks still in play, by song id: shown with a badge in the queue, and
    /// removed if the DJ is dismissed.
    private(set) var generated: Set<String> = []

    @ObservationIgnored private var processed: Set<String> = []
    @ObservationIgnored private var pool: [Song] = []
    @ObservationIgnored private var poolDrawn = false
    @ObservationIgnored private var isProcessing = false
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var artistSongs: [String: [Song]] = [:]
    @ObservationIgnored private weak var appState: AppState?

    init() {
        let defaults = UserDefaults.standard
        dj = defaults.string(forKey: Key.dj).flatMap(GuestDJ.init(rawValue:))
        generated = Set(defaults.stringArray(forKey: Key.generated) ?? [])
        processed = Set(defaults.stringArray(forKey: Key.processed) ?? [])
    }

    func configure(appState: AppState) {
        self.appState = appState
    }

    func isPick(_ song: Song) -> Bool {
        generated.contains(song.id)
    }

    /// Changes DJ. The outgoing one's upcoming picks leave with it, as in Plexamp.
    func setDJ(_ new: GuestDJ?) {
        guard new != dj else { return }
        appState?.player.removeUpcoming(ids: generated)
        dj = new
        UserDefaults.standard.set(new?.rawValue, forKey: Key.dj)
        reset()
        queueChanged()
    }

    /// A new queue: the DJ stays, its memory of the old one goes.
    func queueReplaced() {
        reset()
    }

    func queueChanged() {
        guard dj != nil else { return }
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            await self?.process()
        }
    }

    private func reset() {
        generated = []
        processed = []
        pool = []
        poolDrawn = false
        save()
    }

    private func save() {
        UserDefaults.standard.set(Array(generated), forKey: Key.generated)
        UserDefaults.standard.set(Array(processed), forKey: Key.processed)
    }

    private func process() async {
        guard let dj, let appState, !isProcessing else { return }
        let player = appState.player
        guard let current = player.queue.current,
              let point = GuestDJRules.insertionPoint(for: dj, in: player.queue, generated: generated, processed: processed)
        else { return }

        isProcessing = true
        defer { isProcessing = false }

        let next = player.queue.upcoming(1).first
        let picks = await pick(for: dj, current: current, next: next)

        // The queue may have moved on while the server answered.
        guard self.dj == dj, player.queue.current?.id == current.id,
              GuestDJRules.insertionPoint(for: dj, in: player.queue, generated: generated, processed: processed) == point
        else { return }

        processed.insert(current.id)
        if !picks.isEmpty {
            generated.formUnion(picks.map(\.id))
            player.insertPicks(picks, afterOrderIndex: point)
        }
        // A pool DJ that has played its whole pool is done, and steps aside.
        if dj.keepsTheNextTwo, poolDrawn, pool.isEmpty, picks.isEmpty {
            self.dj = nil
            UserDefaults.standard.removeObject(forKey: Key.dj)
        }
        save()
    }

    private func pick(for dj: GuestDJ, current: Song, next: Song?) async -> [Song] {
        guard let appState else { return [] }
        let client = appState.client
        let queue = appState.player.queue.tracks
        let filter = { (songs: [Song]) in GuestDJRules.filter(songs, queue: queue, generated: self.generated) }

        let sonic = appState.sonic

        switch dj {
        case .gemini:
            // Plexamp's own query: the ten nearest by other artists within 0.175.
            if let twins = await sonic.similarSongs(to: current, limit: 10, excludingArtist: true, maxDistance: 0.175),
               let twin = filter(twins).first {
                return [twin]
            }
            let similar = (try? await client.similarSongs(toSongID: current.id, count: 20)) ?? []
            let others = similar.filter { $0.primaryArtistID != current.primaryArtistID }
            return Array(filter(others).prefix(1))

        case .twofer:
            guard let artist = current.primaryArtistID else { return [] }
            let theirs = await songs(byArtist: artist).filter { $0.id != current.id }
            return Array(filter(theirs.shuffled()).prefix(1))

        case .stretch:
            guard let next else { return [] }
            // Plexamp's: a short sonic adventure from this track to the next, three of its
            // steps at random, kept in order.
            if let path = await sonic.path(from: current, to: next, steps: 8) {
                let steps = filter(path)
                if !steps.isEmpty {
                    let chosen = Set(steps.shuffled().prefix(dj.insertCount).map(\.id))
                    return steps.filter { chosen.contains($0.id) }
                }
            }
            async let from = client.similarSongs(toSongID: current.id, count: 20)
            async let to = client.similarSongs(toSongID: next.id, count: 20)
            let outgoing = filter((try? await from) ?? [])
            let incoming = filter((try? await to) ?? [])
            return GuestDJRules.bridge(fromRelated: outgoing, toRelated: incoming, count: dj.insertCount)

        case .freeze, .contempo, .groupie:
            if !poolDrawn {
                guard let drawn = await drawPool(for: dj, seed: current) else { return [] }
                pool = filter(drawn)
                poolDrawn = true
            }
            pool = filter(pool)
            let taken = Array(pool.prefix(dj.insertCount))
            pool.removeFirst(taken.count)
            return taken
        }
    }

    /// Nil when the pool cannot be drawn from this track at all — Contempo with no year —
    /// so the DJ tries again on the next one rather than giving up.
    private func drawPool(for dj: GuestDJ, seed: Song) async -> [Song]? {
        guard let appState else { return nil }
        let client = appState.client
        let scope = appState.scope.scope

        switch dj {
        case .freeze:
            if let sonic = await appState.sonic.radio(seeds: [seed.id], limit: dj.poolSize) {
                return sonic
            }
            return (try? await client.similarSongs(toSongID: seed.id, count: dj.poolSize)) ?? []
        case .contempo:
            guard let year = seed.year, year > 0 else { return nil }
            return (try? await client.randomSongs(size: dj.poolSize, fromYear: year - 2, toYear: year + 2, scope: scope)) ?? []
        case .groupie:
            guard let artist = seed.primaryArtistID else { return nil }
            return Array(await songs(byArtist: artist).filter { $0.id != seed.id }.shuffled().prefix(dj.poolSize))
        case .stretch, .gemini, .twofer:
            return nil
        }
    }

    /// A whole discography is a request per album, so it is fetched once per artist.
    private func songs(byArtist id: String) async -> [Song] {
        if let known = artistSongs[id] { return known }
        let fetched = (try? await appState?.client.artistSongs(id: id)) ?? []
        artistSongs[id] = fetched
        return fetched
    }
}
