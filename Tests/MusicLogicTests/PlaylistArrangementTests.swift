import Foundation
import Testing

@testable import MusicLogic

/// Pinned playlists first, in his order -- at least four, so no cap at all -- then the
/// rest by the chosen sort, or by hand.
@MainActor
struct PlaylistArrangementTests {
    private func playlist(_ id: String, _ name: String, songs: Int = 0, changed: String? = nil) -> Playlist {
        var playlist = Playlist(id: id, name: name)
        playlist.songCount = songs
        playlist.changed = changed
        return playlist
    }

    private var library: [Playlist] {
        [
            playlist("a", "Alpha", songs: 10, changed: "2026-10-01T00:00:00Z"),
            playlist("b", "Bravo", songs: 50, changed: "2026-10-30T00:00:00Z"),
            playlist("c", "Charlie", songs: 5, changed: "2026-09-01T00:00:00Z"),
            playlist("d", "Delta", songs: 20, changed: "2026-10-20T00:00:00Z"),
            playlist("e", "Echo", songs: 1, changed: "2026-08-01T00:00:00Z"),
            playlist("f", "Foxtrot", songs: 2, changed: "2026-07-01T00:00:00Z"),
        ]
    }

    private func fresh() -> PlaylistArrangement {
        let suite = "test-\(UUID().uuidString)"
        return PlaylistArrangement(defaults: UserDefaults(suiteName: suite)!)
    }

    @Test func fourOrMorePinnedComeFirstInTheirOrder() {
        let arrangement = fresh()
        for id in ["d", "b", "f", "a", "c"] {
            arrangement.togglePin(library.first { $0.id == id }!)
        }
        let split = arrangement.arranged(library)
        #expect(split.pinned.map(\.id) == ["d", "b", "f", "a", "c"])
        #expect(split.rest.map(\.id) == ["e"])
    }

    @Test func unpinningReturnsItToTheRest() {
        let arrangement = fresh()
        let bravo = library[1]
        arrangement.togglePin(bravo)
        arrangement.togglePin(bravo)
        #expect(arrangement.arranged(library).pinned.isEmpty)
    }

    @Test func pinnedOnesMoveAmongThemselves() {
        let arrangement = fresh()
        for playlist in library.prefix(4) { arrangement.togglePin(playlist) }
        let shown = arrangement.arranged(library).pinned
        // Delta, the last, to the top.
        arrangement.movePinned(from: [3], to: 0, shown: shown)
        #expect(arrangement.arranged(library).pinned.map(\.id) == ["d", "a", "b", "c"])
    }

    @Test func eachSortOrdersTheRest() {
        func order(_ sort: PlaylistArrangement.Sort) -> [String] {
            PlaylistArrangement.arrange(library, pinned: [], custom: [], sort: sort).rest.map(\.id)
        }
        #expect(order(.name) == ["a", "b", "c", "d", "e", "f"])
        #expect(order(.recentlyChanged) == ["b", "d", "a", "c", "e", "f"])
        #expect(order(.mostSongs) == ["b", "d", "a", "c", "f", "e"])
    }

    /// Moving one by hand is choosing an order of his own, kept from then on.
    @Test func movingOneByHandMakesItMyOrder() {
        let arrangement = fresh()
        let shown = arrangement.arranged(library).rest
        arrangement.moveRest(from: [4], to: 0, shown: shown)   // Echo to the top
        #expect(arrangement.sort == .custom)
        #expect(arrangement.arranged(library).rest.map(\.id) == ["e", "a", "b", "c", "d", "f"])
    }

    /// A playlist made after the order was chosen goes at the end, by name, until moved.
    @Test func aNewPlaylistJoinsMyOrderAtTheEnd() {
        let split = PlaylistArrangement.arrange(
            library + [playlist("g", "Golf"), playlist("z", "Aardvark")],
            pinned: ["a"], custom: ["c", "b", "d", "e", "f"], sort: .custom
        )
        #expect(split.pinned.map(\.id) == ["a"])
        #expect(split.rest.map(\.id) == ["c", "b", "d", "e", "f", "z", "g"])
    }

    /// A pinned playlist deleted on the server simply is not shown.
    @Test func aPinnedPlaylistThatIsGoneIsLeftOut() {
        let split = PlaylistArrangement.arrange(library, pinned: ["gone", "b"], custom: [], sort: .name)
        #expect(split.pinned.map(\.id) == ["b"])
    }

    @Test func theArrangementIsRemembered() {
        let suite = "test-\(UUID().uuidString)"
        let first = PlaylistArrangement(defaults: UserDefaults(suiteName: suite)!)
        first.togglePin(library[2])
        first.sort = .mostSongs
        let again = PlaylistArrangement(defaults: UserDefaults(suiteName: suite)!)
        #expect(again.pinned == ["c"])
        #expect(again.sort == .mostSongs)
    }

    // MARK: - Add to Playlist's own order

    /// Before he orders it, the picker lists them as the Playlists tab does, pinned first.
    @Test func thePickerStartsWithTheTabsOrder() {
        let arrangement = fresh()
        arrangement.togglePin(library[3])
        #expect(arrangement.forPicker(library).map(\.id) == ["d", "a", "b", "c", "e", "f"])
    }

    @Test func movingOneInThePickerKeepsThatOrder() {
        let arrangement = fresh()
        // Echo, his most used, dragged to the top.
        arrangement.movePicker(from: [4], to: 0, shown: arrangement.forPicker(library))
        #expect(arrangement.forPicker(library).map(\.id) == ["e", "a", "b", "c", "d", "f"])
        // And Alpha below Delta.
        arrangement.movePicker(from: [1], to: 5, shown: arrangement.forPicker(library))
        #expect(arrangement.forPicker(library).map(\.id) == ["e", "b", "c", "d", "a", "f"])
    }

    /// Its own order: the Playlists tab, and its pins, are left as they were.
    @Test func thePickersOrderLeavesTheTabAlone() {
        let arrangement = fresh()
        arrangement.movePicker(from: [5], to: 0, shown: arrangement.forPicker(library))
        #expect(arrangement.sort == .name)
        #expect(arrangement.custom.isEmpty)
        #expect(arrangement.arranged(library).rest.map(\.id) == ["a", "b", "c", "d", "e", "f"])
        // Pinning one later does not move it in an order he has already set.
        arrangement.togglePin(library[3])
        #expect(arrangement.forPicker(library).map(\.id) == ["f", "a", "b", "c", "d", "e"])
    }

    /// A playlist made since goes at the end; one deleted on the server is left out.
    @Test func thePickerTakesNewPlaylistsAtTheEnd() {
        let order = PlaylistArrangement.pickerOrder(
            [playlist("g", "Golf"), playlist("z", "Aardvark")] + library.dropFirst(),
            picker: ["e", "gone", "c", "b"], pinned: [], custom: [], sort: .name
        )
        #expect(order.map(\.id) == ["e", "c", "b", "z", "d", "f", "g"])
    }

    @Test func thePickersOrderIsRemembered() {
        let suite = "test-\(UUID().uuidString)"
        let first = PlaylistArrangement(defaults: UserDefaults(suiteName: suite)!)
        first.movePicker(from: [2], to: 0, shown: first.forPicker(library))
        let again = PlaylistArrangement(defaults: UserDefaults(suiteName: suite)!)
        #expect(again.forPicker(library).map(\.id) == ["c", "a", "b", "d", "e", "f"])
    }
}
