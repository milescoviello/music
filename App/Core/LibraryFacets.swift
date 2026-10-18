import Foundation

/// The ways Plexamp slices a library that Navidrome does not slice for you: a discography
/// by release type, the albums an artist only guests on, record labels, moods, and the
/// albums whose anniversary is today. All derived from albums and songs already fetched,
/// so they are Foundation-only and tested.
enum LibraryFacets {
    struct Group: Identifiable, Sendable {
        let name: String
        let albums: [Album]
        var id: String { name }
    }

    /// A discography split the way Plexamp's artist page splits it, in `ReleaseKind`
    /// order, newest first within each.
    static func byReleaseKind(_ albums: [Album]) -> [(kind: ReleaseKind, albums: [Album])] {
        let grouped = Dictionary(grouping: albums, by: \.kind)
        return ReleaseKind.allCases.compactMap { kind in
            guard let members = grouped[kind], !members.isEmpty else { return nil }
            return (kind, newestFirst(members))
        }
    }

    /// Plexamp's Appears On: albums where the artist is credited on a track but is not the
    /// album artist — the guest verse, the compilation track, the remix.
    static func appearsOn(_ songs: [Song], artistID: String, excluding own: Set<String>) -> [Album] {
        var albums: [String: Album] = [:]
        for song in songs {
            guard let albumID = song.albumId, !own.contains(albumID), albums[albumID] == nil else { continue }
            let credited = song.artistId == artistID || (song.artists ?? []).contains { $0.id == artistID }
            let isAlbumArtist = song.primaryArtistID == artistID
            guard credited, !isAlbumArtist else { continue }

            var album = Album(id: albumID, name: song.album ?? "Unknown Album")
            album.artist = song.albumArtists?.first?.name ?? song.displayArtist ?? song.artist
            album.artistId = song.albumArtists?.first?.id
            album.coverArt = song.coverArt
            album.year = song.year
            albums[albumID] = album
        }
        return newestFirst(Array(albums.values))
    }

    /// Record labels, the biggest first, each with its albums newest first.
    static func labels(_ albums: [Album]) -> [Group] {
        var byLabel: [String: [Album]] = [:]
        for album in albums {
            for label in album.recordLabels ?? [] {
                let name = label.name.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { continue }
                byLabel[name, default: []].append(album)
            }
        }
        return byLabel
            .map { Group(name: $0.key, albums: newestFirst($0.value)) }
            .sorted { $0.albums.count == $1.albums.count ? $0.name < $1.name : $0.albums.count > $1.albums.count }
    }

    /// Moods, as tagged on albums, the most common first.
    static func moods(_ albums: [Album]) -> [Group] {
        var byMood: [String: [Album]] = [:]
        for album in albums {
            for mood in album.moods ?? [] where !mood.isEmpty {
                byMood[mood.capitalized, default: []].append(album)
            }
        }
        return byMood
            .map { Group(name: $0.key, albums: newestFirst($0.value)) }
            .sorted { $0.albums.count == $1.albums.count ? $0.name < $1.name : $0.albums.count > $1.albums.count }
    }

    static func ofKind(_ kind: ReleaseKind, in albums: [Album]) -> [Album] {
        newestFirst(albums.filter { $0.kind == kind })
    }

    /// Plexamp's On This Day: albums first released on today's month and day in an
    /// earlier year, the round anniversaries first.
    static func onThisDay(_ albums: [Album], on date: Date, calendar: Calendar = .current) -> [(album: Album, years: Int)] {
        let today = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = today.year, let month = today.month, let day = today.day else { return [] }

        let matches: [(album: Album, years: Int)] = albums.compactMap { album in
            guard let released = album.originalReleaseDate ?? album.releaseDate,
                  released.month == month, released.day == day,
                  let releasedYear = released.year, releasedYear > 0, releasedYear < year
            else { return nil }
            return (album, year - releasedYear)
        }
        return matches.sorted { lhs, rhs in
            let left = lhs.years % 5 == 0, right = rhs.years % 5 == 0
            return left == right ? lhs.years > rhs.years : left
        }
    }

    /// Plexamp's Best Of: what was released in a year, by how much it has been played.
    static func bestOf(year: Int, in albums: [Album], limit: Int = 25) -> [Album] {
        Array(
            albums
                .filter { $0.year == year && ($0.playCount ?? 0) > 0 }
                .sorted { ($0.playCount ?? 0) > ($1.playCount ?? 0) }
                .prefix(limit)
        )
    }

    /// Albums played a lot once and not for a long time: Plexamp's "Haven't Played In".
    static func notPlayedSince(_ cutoff: Date, in albums: [Album], limit: Int = 25) -> [Album] {
        Array(
            albums
                .filter { album in
                    guard (album.playCount ?? 0) >= 3, let last = album.lastPlayedAt else { return false }
                    return last < cutoff
                }
                .sorted { ($0.playCount ?? 0) > ($1.playCount ?? 0) }
                .prefix(limit)
        )
    }

    private static func newestFirst(_ albums: [Album]) -> [Album] {
        albums.sorted { lhs, rhs in
            let left = lhs.year ?? 0, right = rhs.year ?? 0
            return left == right ? lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending : left > right
        }
    }
}
