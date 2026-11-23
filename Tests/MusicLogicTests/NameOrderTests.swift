import Foundation
import Testing

@testable import MusicLogic

/// The server's A–Z put a title in quotes before every letter.
struct NameOrderTests {
    @Test func punctuationAndArticlesAreSetAside() {
        #expect(NameOrder.key("“The Quiet Hours”") == "quiet hours”")
        #expect(NameOrder.letter("“The Quiet Hours”") == "Q")
        #expect(NameOrder.letter("An Iron Meadow") == "I")
        #expect(NameOrder.letter("Élan") == "E")
        #expect(NameOrder.letter("1999") == "#")
        #expect(NameOrder.letter("The") == "T")
    }

    @Test func albumsSortAsTheyAreFiled() {
        let names = ["Zephyr", "“The Quiet Hours”", "10 Rooms", "A Harbor", "2 Rooms", "Paper Gulls"]
        let albums = names.enumerated().map { Album(id: "\($0.offset)", name: $0.element) }
        #expect(NameOrder.sorted(albums).map(\.name) == ["2 Rooms", "10 Rooms", "A Harbor", "Paper Gulls", "“The Quiet Hours”", "Zephyr"])
    }
}
