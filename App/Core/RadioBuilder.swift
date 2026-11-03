import Foundation

/// Builds an endless-feeling queue from a starting point — the nearest thing to
/// Plexamp's radio that this server can actually do.
///
/// Verified against the live server, and it decides the shape of this file:
/// `getSimilarSongs2` returns results for a **song** id but nothing for an **artist**
/// id, and `getArtistInfo2` returns only images — no biography, no similar artists. So
/// every mix is seeded from a *track*, and artist and genre mixes are assembled here
/// rather than asked for.
///
/// Navidrome computes similarity itself, so unlike `getTopSongs` this needs no Last.fm
/// key.
struct RadioBuilder: Sendable {
    let client: SubsonicClient
    /// For `keeping(_:in:)`. Without it nothing is filtered.
    var native: NavidromeClient?

    /// `songs` less any outside `scope`, in their order.
    ///
    /// `getTopSongs` and `getSimilarSongs2` ignore the folder they are given, so a mix set
    /// to one library was half the other one. Every caller of those two passes the answer
    /// through here. If the server cannot say, everything is kept and the log says so: a
    /// mix with some of the other library beats no mix at all.
    func keeping(_ songs: [Song], in scope: LibraryScope) async -> [Song] {
        guard let libraryID = scope.folderID, let native, !songs.isEmpty else { return songs }
        do {
            let inside = try await native.songIDs(songs.map(\.id), inLibrary: libraryID)
            return songs.filter { inside.contains($0.id) }
        } catch {
            await Diagnostics.shared.record(
                "library", "could not check which library songs are in: \(error.localizedDescription)"
            )
            return songs
        }
    }

    /// A mix around one track: the seed first, then what the server thinks goes with
    /// it, then random padding if similarity came back thin.
    func mix(seed: Song, scope: LibraryScope, size: Int = 50) async -> [Song] {
        var songs = [seed]
        var seen: Set<String> = [seed.id]

        let similar = await keeping(
            (try? await client.similarSongs(toSongID: seed.id, count: size)) ?? [], in: scope
        )
        for song in similar where !seen.contains(song.id) {
            songs.append(song)
            seen.insert(song.id)
        }

        // A cold library, or an obscure track, can return almost nothing. Padding with
        // random tracks keeps a "Radio" button from producing a one-song queue.
        if songs.count < size / 2 {
            let random = (try? await client.randomSongs(size: size, scope: scope)) ?? []
            for song in random where !seen.contains(song.id) && songs.count < size {
                songs.append(song)
                seen.insert(song.id)
            }
        }

        return songs
    }

    /// A genre mix is just a random draw within the genre — the server supports that
    /// directly, and it is genuinely what "genre radio" means.
    func genreMix(_ genre: String, scope: LibraryScope, size: Int = 60) async -> [Song] {
        let random = (try? await client.randomSongs(size: size, genre: genre, scope: scope)) ?? []
        if !random.isEmpty { return random }

        // `getRandomSongs` filters on the song's own genre tag; falling back to the
        // genre listing catches libraries where the tag sits on the album instead.
        return ((try? await client.songsByGenre(genre, count: size, scope: scope)) ?? []).shuffled()
    }

    /// Everything by the artist, shuffled, then extended with similar tracks so it
    /// does not simply stop. Built from the artist's albums because the API has no
    /// "all songs by artist" call.
    func artistMix(_ artist: ArtistRef, scope: LibraryScope, size: Int = 60) async -> [Song] {
        guard let detail = try? await client.artistDetail(id: artist.id) else { return [] }

        var songs: [Song] = []
        var seen: Set<String> = []

        await withTaskGroup(of: [Song].self) { group in
            for album in detail.albums {
                group.addTask { [client] in
                    (try? await client.albumDetail(id: album.id))?.songs ?? []
                }
            }
            for await tracks in group {
                for track in tracks where !seen.contains(track.id) {
                    songs.append(track)
                    seen.insert(track.id)
                }
            }
        }

        songs.shuffle()

        // Extend past the artist's own catalogue, which is what makes it a mix rather
        // than a shuffle of one discography.
        if let seed = songs.first, songs.count < size {
            let similar = await keeping(
                (try? await client.similarSongs(toSongID: seed.id, count: size)) ?? [], in: scope
            )
            for song in similar where !seen.contains(song.id) && songs.count < size {
                songs.append(song)
                seen.insert(song.id)
            }
        }

        return songs
    }
}
