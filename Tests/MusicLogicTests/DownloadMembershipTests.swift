import Foundation
import Testing

@testable import MusicLogic

/// A downloaded song can be on the phone for several playlists and albums at once. It
/// used to have one group, the first download that brought it: downloading a second
/// playlist skipped the songs already here, so that playlist's folder lacked them, and
/// removing the first playlist deleted them although the second still had them.
struct DownloadMembershipTests {
    private func entry(_ id: String, group: String?, name: String? = nil, album: String? = nil) -> DownloadCatalog.Entry {
        var song = Song(id: id, title: "Track \(id)")
        song.albumId = album
        return DownloadCatalog.Entry(
            song: song, filename: "\(id).flac", byteCount: 1, addedAt: .now,
            groupID: group, groupName: name
        )
    }

    private let mainPlaylist = DownloadCatalog.Membership(id: "pl-main", name: "Main")
    private let roadTrip = DownloadCatalog.Membership(id: "pl-road", name: "Road Trip")

    /// Catalogs written before memberships existed read their one group as a list of one.
    @Test func anOldEntryReadsItsGroupAsItsOnlyMembership() throws {
        let old = entry("a", group: "pl-main", name: "Main")
        let decoded = try JSONDecoder().decode(DownloadCatalog.Entry.self, from: JSONEncoder().encode(old))
        #expect(decoded.memberships == [mainPlaylist])
        #expect(entry("b", group: nil).memberships == [.own])
    }

    @Test func aSecondPlaylistJoinsTheSongsAlreadyHere() {
        var catalog = DownloadCatalog()
        catalog.entries["a"] = entry("a", group: "pl-main", name: "Main")
        catalog.pending["b"] = entry("b", group: "pl-main", name: "Main")

        let joined = catalog.join(songIDs: ["a", "b", "not-here"], roadTrip)
        #expect(joined)
        #expect(catalog.entries["a"]?.memberships == [mainPlaylist, roadTrip])
        #expect(catalog.pending["b"]?.memberships == [mainPlaylist, roadTrip])
        #expect(catalog.groupIDs == ["pl-main", "pl-road"])
        #expect(Set(catalog.songIDs(downloadedAs: "pl-road")) == ["a", "b"])
        // Joining again changes nothing.
        let again = catalog.join(songIDs: ["a"], roadTrip)
        #expect(again == false)
    }

    /// The reported bug: removing one playlist's download took songs another downloaded
    /// playlist still had.
    @Test func removingOnePlaylistKeepsWhatAnotherStillHas() {
        var catalog = DownloadCatalog()
        catalog.entries["shared"] = entry("shared", group: "pl-main", name: "Main")
        catalog.entries["only-main"] = entry("only-main", group: "pl-main", name: "Main")
        _ = catalog.join(songIDs: ["shared"], roadTrip)

        let gone = catalog.leave("pl-main")

        #expect(gone.finished.map(\.song.id) == ["only-main"])
        #expect(catalog.entries["shared"]?.memberships == [roadTrip])
        #expect(catalog.entries["only-main"] == nil)
        #expect(catalog.songIDs(downloadedAs: "pl-main").isEmpty)
    }

    /// A song downloaded by itself and later on a playlist stays when the playlist goes.
    @Test func aSongDownloadedByItselfOutlivesItsPlaylist() {
        var catalog = DownloadCatalog()
        catalog.entries["a"] = entry("a", group: nil)
        _ = catalog.join(songIDs: ["a"], mainPlaylist)

        let gone = catalog.leave("pl-main")
        #expect(gone.finished.isEmpty)
        #expect(catalog.entries["a"]?.memberships == [.own])
    }

    /// The sync takes songs off one playlist without touching the rest of it.
    @Test func leavingCanBeForSomeSongsOnly() {
        var catalog = DownloadCatalog()
        catalog.entries["kept"] = entry("kept", group: "pl-main")
        catalog.entries["dropped"] = entry("dropped", group: "pl-main")
        catalog.pending["dropped-waiting"] = entry("dropped-waiting", group: "pl-main")

        let gone = catalog.leave("pl-main", songIDs: ["dropped", "dropped-waiting"])
        #expect(gone.finished.map(\.song.id) == ["dropped"])
        #expect(gone.waiting.map(\.song.id) == ["dropped-waiting"])
        #expect(Array(catalog.entries.keys) == ["kept"])
    }

    /// A song downloaded by itself is part of its album's download, where the Downloads
    /// screen files it, and leaves with the album.
    @Test func aLoneSongBelongsToItsAlbumsDownload() {
        var catalog = DownloadCatalog()
        catalog.entries["a"] = entry("a", group: nil, album: "al1")
        #expect(catalog.songIDs(downloadedAs: "al1") == ["a"])
        let gone = catalog.leave("al1")
        #expect(gone.finished.map(\.song.id) == ["a"])
    }

    @Test func membershipsSurviveBeingSaved() throws {
        var catalog = DownloadCatalog()
        catalog.entries["a"] = entry("a", group: "pl-main", name: "Main")
        _ = catalog.join(songIDs: ["a"], roadTrip)
        let decoded = try JSONDecoder().decode(DownloadCatalog.self, from: JSONEncoder().encode(catalog))
        #expect(decoded.entries["a"]?.memberships == [mainPlaylist, roadTrip])
    }

    /// The Downloads screen: a shared song is in both playlists' folders, and each folder
    /// has its own name -- the first group's name used to title the second's.
    @Test func aSharedSongIsInEveryPlaylistsFolder() {
        var catalog = DownloadCatalog()
        catalog.entries["shared"] = entry("shared", group: "pl-main", name: "Main", album: "al1")
        catalog.entries["road-only"] = entry("road-only", group: "pl-road", name: "Road Trip", album: "al2")
        _ = catalog.join(songIDs: ["shared"], roadTrip)

        let folders = DownloadFolders(catalog: catalog)
        let byName = Dictionary(uniqueKeysWithValues: folders.playlists.map { ($0.name, Set($0.songs.map(\.id))) })
        #expect(byName == ["Main": ["shared"], "Road Trip": ["shared", "road-only"]])
        #expect(folders.albums.isEmpty)
    }

    // MARK: - The album or playlist download button

    /// Playlist "Main" is downloading, and shares "shared" with "Road Trip". Road Trip's
    /// button read as Main's ring, and tapping it removed a Road Trip download that did
    /// not exist, so Road Trip could not be downloaded until Main was done.
    @Test func anotherDownloadStillArrivingDoesNotTakeOverThisButton() {
        var catalog = DownloadCatalog()
        catalog.entries["main-done"] = entry("main-done", group: "pl-main", name: "Main")
        catalog.pending["shared"] = entry("shared", group: "pl-main", name: "Main")
        let progress = ["shared": 0.4]

        let road = catalog.collectionState(of: ["shared", "road-only"], groupID: "pl-road", progress: progress, asked: false)
        #expect(road == .none)
        let main = catalog.collectionState(of: ["main-done", "shared"], groupID: "pl-main", progress: progress, asked: false)
        #expect(main == .working(fraction: 0.7))
    }

    /// Between the tap and the catalog write, the songs have progress but no entry.
    @Test func justAskedForReadsAsArriving() {
        let catalog = DownloadCatalog()
        let state = catalog.collectionState(of: ["a", "b"], groupID: "pl-road", progress: ["a": 0, "b": 0], asked: true)
        #expect(state == .working(fraction: 0))
    }

    /// Once Road Trip joins the shared song, the button follows its own download.
    @Test func aJoinedSongCountsForBothDownloads() {
        var catalog = DownloadCatalog()
        catalog.pending["shared"] = entry("shared", group: "pl-main", name: "Main")
        catalog.entries["road-only"] = entry("road-only", group: "pl-road", name: "Road Trip")
        _ = catalog.join(songIDs: ["shared"], roadTrip)

        let road = catalog.collectionState(of: ["shared", "road-only"], groupID: "pl-road", progress: [:], asked: false)
        #expect(road == .working(fraction: 0.5))
        catalog.entries["shared"] = catalog.pending.removeValue(forKey: "shared")
        #expect(catalog.collectionState(of: ["shared", "road-only"], groupID: "pl-road", progress: [:], asked: false) == .complete)
    }

    /// Every song on the device, but for other playlists: a tap makes it this one's too,
    /// where a check would have been a button that removes nothing.
    @Test func songsHereOnlyForOtherDownloadsAreNotThisOnesDownload() {
        var catalog = DownloadCatalog()
        catalog.entries["a"] = entry("a", group: "pl-main", name: "Main")
        catalog.entries["b"] = entry("b", group: "pl-main", name: "Main")
        #expect(catalog.collectionState(of: ["a", "b"], groupID: "pl-road", progress: [:], asked: false) == .none)
    }

    /// Songs downloaded one at a time are their album's download, as the Downloads screen
    /// files them.
    @Test func anAlbumDownloadedSongBySongIsComplete() {
        var catalog = DownloadCatalog()
        catalog.entries["one"] = entry("one", group: nil, album: "al-1")
        catalog.entries["two"] = entry("two", group: nil, album: "al-1")
        #expect(catalog.collectionState(of: ["one", "two"], groupID: "al-1", progress: [:], asked: false) == .complete)
        #expect(catalog.collectionState(of: ["one", "two", "three"], groupID: "al-1", progress: [:], asked: false) == .none)
    }
}
