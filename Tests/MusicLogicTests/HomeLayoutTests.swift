import Foundation
import Testing
@testable import MusicLogic

struct HomeLayoutTests {
    @Test func theDefaultShowsEverythingInOrder() {
        #expect(HomeLayout.default.visible == HomeHub.allCases)
    }

    @Test func hidingAndMovingSurviveBeingSaved() {
        var layout = HomeLayout.default
        layout.setVisible(false, .mostPlayed)
        layout.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        let restored = HomeLayout.restored(from: layout.encoded)
        #expect(restored == layout)
        #expect(restored.order.first == .recentlyPlayed)
        #expect(!restored.visible.contains(.mostPlayed))
    }

    @Test func movingDownLandsWhereSwiftUISays() {
        var layout = HomeLayout.default
        // Moving the first to offset 3 puts it after the next two, as `onMove` reports.
        layout.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        #expect(Array(layout.order.prefix(3)) == [.stations, .recentlyPlayed, .madeForYou])
    }

    @Test func aStoredLayoutIsRepairedNotDiscarded() {
        let stored = Data(#"{"order":["favourites","gone","favourites","madeForYou"],"hidden":["gone","stations"]}"#.utf8)
        let layout = HomeLayout.restored(from: stored)
        #expect(Set(layout.order) == Set(HomeHub.allCases))
        #expect(layout.order.count == HomeHub.allCases.count)
        #expect(layout.order.first == .favourites)
        #expect(!layout.isVisible(.stations))
        #expect(HomeLayout.restored(from: Data("junk".utf8)) == .default)
    }
}
