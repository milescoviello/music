import Foundation

/// Plexamp's Guest DJs: a DJ that slips its own picks into the queue as it plays.
///
/// Two kinds, as in Plexamp. **Per-track** DJs — Stretch, Gemini, Twofer — add their picks
/// after every track you queued, so the queue alternates between yours and theirs.
/// **Pool** DJs — Freeze, Contempo, Groupie — draw a pool once from the track playing when
/// they start, then keep the next two tracks theirs until the pool runs out, which is how
/// they "keep the mood going". Friendgänger needs other people's libraries on a shared
/// server, and is left out.
///
/// Plexamp's DJs that speak of sonic similarity use Plex's sonic analysis. Navidrome's
/// nearest equivalent is its similar-songs list (similar artists, via its agents), so
/// those DJs are approximations, and their descriptions say so.
enum GuestDJ: String, Codable, CaseIterable, Identifiable, Sendable {
    case stretch
    case gemini
    case twofer
    case freeze
    case contempo
    case groupie

    var id: String { rawValue }

    var name: String {
        switch self {
        case .stretch: return "DJ Stretch"
        case .gemini: return "DJ Gemini"
        case .twofer: return "DJ Twofer"
        case .freeze: return "DJ Freeze"
        case .contempo: return "DJ Contempo"
        case .groupie: return "DJ Groupie"
        }
    }

    var summary: String {
        switch self {
        case .stretch: return "Inserts a short bridge of related tracks between each pair of tracks."
        case .gemini: return "Inserts the closest related track by another artist after each track."
        case .twofer: return "Inserts another track by the same artist after each track."
        case .freeze: return "Keeps the mood going with tracks related to the current one."
        case .contempo: return "Keeps the mood going with tracks from the same era."
        case .groupie: return "Keeps queueing tracks from the same artist."
        }
    }

    /// Pool DJs keep the next two tracks theirs; per-track DJs act once per track.
    var keepsTheNextTwo: Bool {
        [.freeze, .contempo, .groupie].contains(self)
    }

    /// How many tracks one step inserts: Plexamp's 3 for Stretch, 1 for the other
    /// per-track DJs, and 2 at a time from a pool.
    var insertCount: Int {
        switch self {
        case .stretch: return 3
        case .gemini, .twofer: return 1
        case .freeze, .contempo, .groupie: return 2
        }
    }

    /// Pool sizes, Plexamp's: 75 tracks of radio, 50 of an era or an artist.
    var poolSize: Int {
        self == .freeze ? 75 : 50
    }
}

/// Plexamp's DJ rules, Foundation-only so they are tested.
enum GuestDJRules {
    /// Plexamp's title cleaning: a trailing "(Live)" or "[2011 Remaster]" goes, so a DJ
    /// does not queue a second version of something already there.
    static func cleanTitle(_ title: String) -> String {
        var text = title
        if let range = text.range(of: #"^(.*[a-zA-Z ]+)[(\[].+[)\]]$"#, options: .regularExpression),
           range == text.startIndex..<text.endIndex,
           let open = text.lastIndex(where: { $0 == "(" || $0 == "[" }) {
            text = String(text[..<open])
        }
        return text
            .replacingOccurrences(of: #" +"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
    }

    /// Plexamp's shared filters: not in the queue already (by id or cleaned title), not
    /// rated below the middle, between 90 seconds and 10 minutes, and not picked before.
    ///
    /// Plexamp's rating floor is 5 of 10 — two and a half stars. Navidrome rates in whole
    /// stars, so one and two are out and three and up (or unrated) are in.
    static func filter(_ candidates: [Song], queue: [Song], generated: Set<String>) -> [Song] {
        let queuedIDs = Set(queue.map(\.id))
        var queuedTitles = Set(queue.map { cleanTitle($0.title) })
        var picked: [Song] = []

        for song in candidates {
            guard !queuedIDs.contains(song.id), !generated.contains(song.id) else { continue }
            let title = cleanTitle(song.title)
            guard !queuedTitles.contains(title) else { continue }
            if let rating = song.userRating, rating > 0, rating < 3 { continue }
            if let duration = song.duration, duration <= 90 || duration >= 600 { continue }
            picked.append(song)
            // Two candidates with one title are one song, for this purpose.
            queuedTitles.insert(title)
        }
        return picked
    }

    /// Where the DJ should insert next — after this order index — or nil when it has
    /// nothing to do right now.
    ///
    /// Per-track DJs act once on each track that is not theirs. Pool DJs act whenever the
    /// next two tracks are not already both theirs, inserting after the last of the two
    /// that is.
    static func insertionPoint(
        for dj: GuestDJ,
        in queue: PlaybackQueue,
        generated: Set<String>,
        processed: Set<String>
    ) -> Int? {
        guard let current = queue.current else { return nil }

        func song(at offset: Int) -> Song? {
            let index = queue.position + offset
            guard queue.order.indices.contains(index), queue.tracks.indices.contains(queue.order[index]) else { return nil }
            return queue.tracks[queue.order[index]]
        }

        if dj.keepsTheNextTwo {
            let next = song(at: 1)
            let afterNext = song(at: 2)
            let nextIsTheirs = next.map { generated.contains($0.id) } ?? false
            let afterNextIsTheirs = afterNext.map { generated.contains($0.id) } ?? false
            if nextIsTheirs && afterNextIsTheirs { return nil }
            return nextIsTheirs ? queue.position + 1 : queue.position
        }

        guard !generated.contains(current.id), !processed.contains(current.id) else { return nil }
        // Stretch builds a bridge *to* the next track, so it needs one.
        if dj == .stretch, song(at: 1) == nil { return nil }
        return queue.position
    }

    /// Stretch's bridge from `current` to `next`: tracks related to both first, then
    /// alternately to one and the other, so the three move from where you are towards
    /// where you are going.
    static func bridge(fromRelated outgoing: [Song], toRelated incoming: [Song], count: Int) -> [Song] {
        let incomingIDs = Set(incoming.map(\.id))
        let shared = outgoing.filter { incomingIDs.contains($0.id) }
        var picked = Array(shared.prefix(count))
        var seen = Set(picked.map(\.id))

        var outgoingRest = outgoing.filter { !seen.contains($0.id) }.makeIterator()
        var incomingRest = incoming.filter { !seen.contains($0.id) }.makeIterator()
        var takeOutgoing = true
        while picked.count < count {
            let next = takeOutgoing ? (outgoingRest.next() ?? incomingRest.next()) : (incomingRest.next() ?? outgoingRest.next())
            guard let song = next else { break }
            takeOutgoing.toggle()
            guard !seen.contains(song.id) else { continue }
            seen.insert(song.id)
            picked.append(song)
        }
        // From the outgoing track's side, through what the two share, to the incoming's.
        let outgoingIDs = Set(outgoing.map(\.id))
        func side(_ song: Song) -> Int {
            switch (outgoingIDs.contains(song.id), incomingIDs.contains(song.id)) {
            case (true, false): return 0
            case (true, true): return 1
            default: return 2
            }
        }
        return [0, 1, 2].flatMap { group in picked.filter { side($0) == group } }
    }
}
