import Foundation

/// A year in music, from the play log: what Spotify calls Wrapped. Everything here is
/// counted from plays the apps recorded themselves, on every device that shares its
/// taste, so it starts when the log does and says so.
struct Recap: Sendable {
    struct Play: Sendable {
        var songID: String?
        var title: String
        var artist: String
        var album: String
        var albumID: String?
        var coverArt: String?
        var genre: String?
        /// Seconds.
        var duration: Int
        var at: Date
    }

    struct Entry: Sendable, Identifiable, Equatable {
        var id: String
        /// For a song, the copy played last, to play it again.
        var songID: String?
        var name: String
        var detail: String?
        var coverArt: String?
        var albumID: String?
        var plays: Int
        var minutes: Int
    }

    struct Month: Sendable, Equatable {
        var month: Int
        var artist: String
        var minutes: Int
    }

    var year: Int
    /// The first play of the year in the log: before it, nothing was recorded.
    var since: Date?
    var plays: Int
    var minutes: Int
    var songCount: Int
    var artistCount: Int
    var albumCount: Int
    var topSongs: [Entry]
    var topArtists: [Entry]
    var topAlbums: [Entry]
    var topGenres: [Entry]
    var biggestDay: (date: Date, minutes: Int)?
    var longestStreak: Int
    /// 0–23, the hour most listened in.
    var favouriteHour: Int?
    var months: [Month]

    var isEmpty: Bool { plays == 0 }

    static func make(_ all: [Play], year: Int, calendar: Calendar = .current, limit: Int = 10) -> Recap {
        let plays = all.filter { calendar.component(.year, from: $0.at) == year }.sorted { $0.at < $1.at }
        func minutes(_ group: [Play]) -> Int { group.reduce(0) { $0 + $1.duration } / 60 }

        func rank(byMinutes: Bool = false, _ key: (Play) -> String?, _ make: (String, [Play]) -> Entry) -> [Entry] {
            Dictionary(grouping: plays.compactMap { play in key(play).map { ($0, play) } }, by: \.0)
                .map { make($0.key, $0.value.map(\.1)) }
                .sorted { a, b in
                    let (first, second) = byMinutes ? (a.minutes, b.minutes) : (a.plays, b.plays)
                    let (third, fourth) = byMinutes ? (a.plays, b.plays) : (a.minutes, b.minutes)
                    return first != second ? first > second : (third != fourth ? third > fourth : a.name < b.name)
                }
        }

        // Copies of a song or an album in the two libraries count as one.
        let songs = rank({ "\($0.artist.lowercased())|\($0.title.lowercased())" }) { key, group in
            Entry(id: key, songID: group.last?.songID, name: group[0].title, detail: group[0].artist, coverArt: group.last?.coverArt,
                  albumID: group.last?.albumID, plays: group.count, minutes: minutes(group))
        }
        // Artists by time listened, as they are shown: by plays, a band of short songs
        // outranked one with fewer, longer ones while showing fewer minutes.
        let artists = rank(byMinutes: true, { $0.artist.isEmpty ? nil : $0.artist.lowercased() }) { key, group in
            Entry(id: key, name: group[0].artist, detail: nil, coverArt: group.last?.coverArt,
                  albumID: nil, plays: group.count, minutes: minutes(group))
        }
        let albums = rank({ "\($0.artist.lowercased())|\($0.album.lowercased())" }) { key, group in
            Entry(id: key, name: group[0].album, detail: group[0].artist, coverArt: group.last?.coverArt,
                  albumID: group.last?.albumID, plays: group.count, minutes: minutes(group))
        }
        let genres = rank({ $0.genre.flatMap { $0.isEmpty ? nil : $0 } }) { key, group in
            Entry(id: key, name: key, detail: nil, coverArt: nil, albumID: nil, plays: group.count, minutes: minutes(group))
        }

        let byDay = Dictionary(grouping: plays) { calendar.startOfDay(for: $0.at) }
        let biggest = byDay.map { (date: $0.key, minutes: minutes($0.value)) }
            .max { $0.minutes != $1.minutes ? $0.minutes < $1.minutes : $0.date > $1.date }

        var longest = 0, run = 0
        var previous: Date?
        for day in byDay.keys.sorted() {
            if let previous, calendar.dateComponents([.day], from: previous, to: day).day == 1 {
                run += 1
            } else {
                run = 1
            }
            longest = max(longest, run)
            previous = day
        }

        let byHour = Dictionary(grouping: plays) { calendar.component(.hour, from: $0.at) }
        let hour = byHour.max { $0.value.count != $1.value.count ? $0.value.count < $1.value.count : $0.key > $1.key }?.key

        let months = Dictionary(grouping: plays) { calendar.component(.month, from: $0.at) }
            .compactMap { month, group -> Month? in
                let top = Dictionary(grouping: group, by: \.artist).max { minutes($0.value) < minutes($1.value) }
                return top.map { Month(month: month, artist: $0.key, minutes: minutes($0.value)) }
            }
            .sorted { $0.month < $1.month }

        return Recap(
            year: year, since: plays.first?.at, plays: plays.count, minutes: minutes(plays),
            songCount: songs.count, artistCount: artists.count, albumCount: albums.count,
            topSongs: Array(songs.prefix(limit)), topArtists: Array(artists.prefix(limit)),
            topAlbums: Array(albums.prefix(limit)), topGenres: Array(genres.prefix(5)),
            biggestDay: biggest, longestStreak: longest, favouriteHour: hour, months: months
        )
    }

    /// "9 PM", for the favourite hour.
    static func hourName(_ hour: Int) -> String {
        let suffix = hour < 12 ? "AM" : "PM"
        let twelve = hour % 12 == 0 ? 12 : hour % 12
        return "\(twelve) \(suffix)"
    }
}
