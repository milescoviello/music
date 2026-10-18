import Foundation
import Testing

@testable import MusicLogic

/// The Downloads tab is folders: albums and playlists, never a loose song. These pin
/// where each kind of download lands, because the catalog only records a group id and
/// the screen has to work out from that alone what the user downloaded.
struct DownloadFoldersTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func song(
        _ id: String,
        album: String = "OK Computer",
        albumID: String? = "al1",
        artist: String = "Radiohead",
        track: Int = 1,
        disc: Int? = nil,
        duration: Int = 200
    ) -> Song {
        var song = Song(id: id, title: "Track \(id)")
        song.album = album
        song.albumId = albumID
        song.artist = artist
        song.track = track
        song.discNumber = disc
        song.duration = duration
        song.coverArt = "cover-\(albumID ?? id)"
        return song
    }

    private func entry(
        _ song: Song,
        group: String? = nil,
        groupName: String? = nil,
        bytes: Int64 = 1_000,
        minutes: Double = 0
    ) -> DownloadCatalog.Entry {
        DownloadCatalog.Entry(
            song: song,
            filename: "\(song.id).flac",
            byteCount: bytes,
            addedAt: start.addingTimeInterval(minutes * 60),
            groupID: group,
            groupName: groupName
        )
    }

    private func catalog(
        done: [DownloadCatalog.Entry] = [],
        waiting: [DownloadCatalog.Entry] = []
    ) -> DownloadCatalog {
        var catalog = DownloadCatalog()
        for entry in done { catalog.entries[entry.song.id] = entry }
        for entry in waiting { catalog.pending[entry.song.id] = entry }
        return catalog
    }

    // MARK: - Where things land

    @Test func anAlbumDownloadIsOneFolderInTrackOrder() {
        let folders = DownloadFolders(catalog: catalog(done: [
            entry(song("b", track: 2), group: "al1", groupName: "OK Computer"),
            entry(song("a", track: 1), group: "al1", groupName: "OK Computer"),
            entry(song("c", track: 1, disc: 2), group: "al1", groupName: "OK Computer"),
        ]))

        #expect(folders.albums.count == 1)
        #expect(folders.playlists.isEmpty)
        let album = folders.albums[0]
        #expect(album.kind == .album)
        #expect(album.name == "OK Computer")
        #expect(album.artist == "Radiohead")
        #expect(album.songs.map(\.id) == ["a", "b", "c"])
        #expect(album.byteCount == 3_000)
        #expect(album.duration == 600)
    }

    /// The user's own words: a single song is never a loose row.
    @Test func aSingleSongLandsInItsAlbumsFolder() {
        let folders = DownloadFolders(catalog: catalog(done: [
            entry(song("a", track: 1), group: "al1", groupName: "OK Computer"),
            entry(song("z", track: 9)),
        ]))

        #expect(folders.albums.count == 1)
        #expect(folders.albums[0].songs.map(\.id) == ["a", "z"])
    }

    @Test func aSingleSongOnItsOwnMakesAnAlbumFolder() {
        let folders = DownloadFolders(catalog: catalog(done: [
            entry(song("z", album: "Kid A", albumID: "al2")),
        ]))

        #expect(folders.albums.map(\.name) == ["Kid A"])
        #expect(folders.albums[0].songs.map(\.id) == ["z"])
        #expect(folders.playlists.isEmpty)
    }

    @Test func playlistsFavouritesAndMixesArePlaylists() {
        let folders = DownloadFolders(catalog: catalog(done: [
            entry(song("a", albumID: "al1"), group: "pl1", groupName: "Road Trip"),
            entry(song("b", albumID: "al2"), group: "favourites", groupName: "Favourites"),
            entry(song("c", albumID: "al3"), group: "mix-1", groupName: "Daily Mix 1"),
        ]))

        #expect(folders.albums.isEmpty)
        #expect(Set(folders.playlists.map(\.name)) == ["Road Trip", "Favourites", "Daily Mix 1"])
        #expect(folders.playlists.allSatisfy { $0.kind == .playlist && $0.artist == nil })
    }

    /// A playlist's songs do not each become an album folder: that would be every song
    /// at once again, just with more rows.
    @Test func aPlaylistDoesNotSpawnAlbumFolders() {
        let folders = DownloadFolders(catalog: catalog(done: [
            entry(song("a", albumID: "al1"), group: "pl1", groupName: "Mix"),
            entry(song("b", albumID: "al2"), group: "pl1", groupName: "Mix"),
            entry(song("c", albumID: "al3"), group: "pl1", groupName: "Mix"),
        ]))

        #expect(folders.albums.isEmpty)
        #expect(folders.playlists.count == 1)
        #expect(folders.playlists[0].trackCount == 3)
    }

    /// Downloading an album skips a song a playlist already brought; the album's folder
    /// still has to show it.
    @Test func anAlbumFolderIncludesItsSongsFromAPlaylist() {
        let folders = DownloadFolders(catalog: catalog(done: [
            entry(song("a", track: 1), group: "pl1", groupName: "Mix"),
            entry(song("b", track: 2), group: "al1", groupName: "OK Computer"),
        ]))

        #expect(folders.albums.first?.songs.map(\.id) == ["a", "b"])
        #expect(folders.playlists.first?.songs.map(\.id) == ["a"])
    }

    @Test func aCompilationIsByVariousArtists() {
        let folders = DownloadFolders(catalog: catalog(done: [
            entry(song("a", artist: "One", track: 1), group: "al1"),
            entry(song("b", artist: "Two", track: 2), group: "al1"),
        ]))
        #expect(folders.albums.first?.artist == "Various Artists")
    }

    @Test func theAlbumArtistWinsOverTrackArtists() {
        var guest = song("b", artist: "Two", track: 2)
        guest.albumArtists = [ArtistLink(id: "ar1", name: "One")]
        let folders = DownloadFolders(catalog: catalog(done: [
            entry(song("a", artist: "One", track: 1), group: "al1"),
            entry(guest, group: "al1"),
        ]))
        #expect(folders.albums.first?.artist == "One")
    }

    // MARK: - While downloading

    @Test func progressIsWholeTracksFromTheCatalog() {
        let folders = DownloadFolders(catalog: catalog(
            done: [entry(song("a", track: 1), group: "al1")],
            waiting: [
                entry(song("b", track: 2), group: "al1"),
                entry(song("c", track: 3), group: "al1"),
                entry(song("d", track: 4), group: "al1"),
            ]
        ))

        let album = folders.albums[0]
        #expect(album.isDownloading)
        #expect(album.trackCount == 4)
        #expect(album.songs.map(\.id) == ["a"])
        #expect(album.waiting.map(\.id) == ["b", "c", "d"])
        #expect(album.fractionDone == 0.25)
        // Only what is on disk counts toward its size.
        #expect(album.byteCount == 1_000)
    }

    @Test func aFolderThatIsOnlyWaitingIsStillShown() {
        let folders = DownloadFolders(catalog: catalog(waiting: [
            entry(song("a", albumID: "al9"), group: "pl1", groupName: "Queued"),
        ]))

        #expect(folders.playlists.first?.name == "Queued")
        #expect(folders.playlists.first?.songs.isEmpty == true)
        #expect(folders.playlists.first?.fractionDone == 0)
        // Search and Play All only offer what can play offline.
        #expect(folders.songs.isEmpty)
    }

    // MARK: - Playlist order

    @Test func aPlaylistFollowsItsCachedOrder() {
        let catalog = catalog(done: [
            entry(song("a", albumID: "x1"), group: "pl1", groupName: "Mix", minutes: 1),
            entry(song("b", albumID: "x2"), group: "pl1", groupName: "Mix", minutes: 2),
            entry(song("c", albumID: "x3"), group: "pl1", groupName: "Mix", minutes: 3),
        ])

        let arrived = DownloadFolders(catalog: catalog)
        #expect(arrived.playlists[0].songs.map(\.id) == ["a", "b", "c"])

        let ordered = DownloadFolders(catalog: catalog, playlistOrders: ["pl1": ["c", "a", "b"]])
        #expect(ordered.playlists[0].songs.map(\.id) == ["c", "a", "b"])
    }

    /// A playlist downloaded after an album skips the songs the album already brought;
    /// its cached order puts them back where they belong.
    @Test func aCachedOrderBringsInSongsFiledElsewhere() {
        let folders = DownloadFolders(
            catalog: catalog(done: [
                entry(song("a", track: 1), group: "al1", groupName: "OK Computer"),
                entry(song("p", albumID: "x1"), group: "pl1", groupName: "Mix"),
            ]),
            playlistOrders: ["pl1": ["p", "a", "missing"]]
        )

        #expect(folders.playlists[0].songs.map(\.id) == ["p", "a"])
        // Still in its album, too.
        #expect(folders.albums[0].songs.map(\.id) == ["a"])
    }

    @Test func songsDroppedFromThePlaylistKeepTheirPlaceAtTheEnd() {
        let folders = DownloadFolders(
            catalog: catalog(done: [
                entry(song("a", albumID: "x1"), group: "pl1", groupName: "Mix", minutes: 1),
                entry(song("gone", albumID: "x2"), group: "pl1", groupName: "Mix", minutes: 2),
            ]),
            playlistOrders: ["pl1": ["a"]]
        )
        #expect(folders.playlists[0].songs.map(\.id) == ["a", "gone"])
    }

    // MARK: - Sorting

    @Test func addedAtIsOldestFirstAndFlips() {
        let folders = DownloadFolders(catalog: catalog(done: [
            entry(song("a", album: "Second", albumID: "al2"), group: "al2", minutes: 2),
            entry(song("b", album: "First", albumID: "al1"), group: "al1", minutes: 1),
            entry(song("c", album: "Third", albumID: "al3"), group: "al3", minutes: 3),
        ]))

        let ascending = folders.sorted(folders.albums, by: .addedAt, ascending: true)
        #expect(ascending.map(\.name) == ["First", "Second", "Third"])
        let descending = folders.sorted(folders.albums, by: .addedAt, ascending: false)
        #expect(descending.map(\.name) == ["Third", "Second", "First"])
    }

    /// A folder still filling up keeps its place: the first track asked for decides.
    @Test func aFolderIsDatedByItsFirstTrack() {
        let folders = DownloadFolders(catalog: catalog(done: [
            entry(song("a", album: "Early", albumID: "al1", track: 1), group: "al1", minutes: 1),
            entry(song("b", album: "Middle", albumID: "al2"), group: "al2", minutes: 5),
            entry(song("c", album: "Early", albumID: "al1", track: 2), group: "al1", minutes: 9),
        ]))
        #expect(folders.albums.map(\.name) == ["Early", "Middle"])
    }

    @Test func nameIgnoresCaseAccentsAndALeadingThe() {
        let folders = DownloadFolders(catalog: catalog(done: [
            entry(song("a", album: "The Bends", albumID: "al1"), group: "al1"),
            entry(song("b", album: "amnesiac", albumID: "al2"), group: "al2"),
            entry(song("c", album: "Électrique", albumID: "al3"), group: "al3"),
        ]))

        let byName = folders.sorted(folders.albums, by: .name, ascending: true)
        #expect(byName.map(\.name) == ["amnesiac", "The Bends", "Électrique"])
        let reversed = folders.sorted(folders.albums, by: .name, ascending: false)
        #expect(reversed.map(\.name) == ["Électrique", "The Bends", "amnesiac"])
    }

    @Test func playAllFollowsTheShownOrderWithoutRepeats() {
        let folders = DownloadFolders(catalog: catalog(done: [
            entry(song("a", album: "B Album", albumID: "al1"), group: "al1", minutes: 1),
            entry(song("p", album: "A Album", albumID: "al2"), group: "pl1", groupName: "Mix", minutes: 2),
            entry(song("q", album: "B Album", albumID: "al1", track: 2), group: "pl1", groupName: "Mix", minutes: 3),
        ]))

        // "q" is in both the album and the playlist, and plays once.
        #expect(folders.playAll(sort: .addedAt, ascending: true).map(\.id) == ["a", "q", "p"])
    }

    // MARK: - Search

    @Test func searchFindsFoldersAndSongsByEveryWord() {
        var lucky = Song(id: "l", title: "Lucky")
        lucky.album = "OK Computer"
        lucky.albumId = "al1"
        lucky.artist = "Radiohead"

        let folders = DownloadFolders(catalog: catalog(done: [
            entry(lucky, group: "al1", groupName: "OK Computer"),
            entry(song("n", album: "Nevermind", albumID: "al2", artist: "Nirvana"), group: "al2"),
            entry(song("r", album: "Road", albumID: "al3", artist: "Röyksopp"), group: "pl1", groupName: "Road Trip"),
        ]))

        let byAlbum = folders.search("ok radiohead")
        #expect(byAlbum.albums.map(\.name) == ["OK Computer"])
        #expect(byAlbum.songs.map(\.id) == ["l"])

        let byTitle = folders.search("LUCKY")
        #expect(byTitle.albums.isEmpty)
        #expect(byTitle.songs.map(\.id) == ["l"])

        let byPlaylist = folders.search("road trip")
        #expect(byPlaylist.playlists.map(\.name) == ["Road Trip"])

        let accentless = folders.search("royksopp")
        #expect(accentless.songs.map(\.id) == ["r"])

        #expect(folders.search("   ").isEmpty)
        #expect(folders.search("portishead").isEmpty)
    }

    // MARK: - Removing

    @Test func removingAFolderKeepsSongsAnotherFolderShows() {
        let folders = DownloadFolders(catalog: catalog(
            done: [
                entry(song("a", track: 1), group: "pl1", groupName: "Mix"),
                entry(song("b", track: 2), group: "al1", groupName: "OK Computer"),
                entry(song("p", albumID: "x1"), group: "pl1", groupName: "Mix"),
            ],
            waiting: [entry(song("w", albumID: "x2"), group: "pl1", groupName: "Mix")]
        ))

        let album = folders.albums[0]
        let playlist = folders.playlists[0]
        // "a" is in both: removing either folder leaves it for the other.
        #expect(Set(folders.songIDsToRemove(for: album)) == ["b"])
        // A transfer still running for the playlist is cancelled with it.
        #expect(Set(folders.songIDsToRemove(for: playlist)) == ["p", "w"])
    }

    @Test func foldersAreFoundByID() {
        let folders = DownloadFolders(catalog: catalog(done: [
            entry(song("a"), group: "al1"),
            entry(song("p", albumID: "x1"), group: "al1-not-an-album", groupName: "Mix"),
        ]))
        #expect(folders.folder(id: "album:al1")?.name == "OK Computer")
        #expect(folders.folder(id: "playlist:al1-not-an-album")?.name == "Mix")
        #expect(folders.folder(id: "album:nope") == nil)
    }

    @Test func totalsCountOnlyWhatIsOnThePhone() {
        let folders = DownloadFolders(catalog: catalog(
            done: [entry(song("a", duration: 100), bytes: 500), entry(song("b", track: 2, duration: 50), bytes: 250)],
            waiting: [entry(song("c", track: 3), bytes: 9_999)]
        ))
        #expect(folders.totalBytes == 750)
        #expect(folders.totalDuration == 150)
        #expect(folders.songs.count == 2)
    }
}
