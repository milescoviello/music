import Foundation
import Testing

@testable import MusicLogic

/// Two editions of one record looked like the same album twice: what told them apart was
/// past the end of the card's line.
struct AlbumEditionTests {
    @Test func anEditionOnTheEndIsSetApart() {
        #expect(AlbumEdition.split("Paper Gulls (Vinyl rip)") == ("Paper Gulls", "Vinyl rip"))
        #expect(AlbumEdition.split("Tidewater [2019 Remaster]") == ("Tidewater", "2019 Remaster"))
        #expect(AlbumEdition.split("Iron Meadow (Deluxe Edition) [24-bit]") == ("Iron Meadow", "Deluxe Edition · 24-bit"))
    }

    @Test func aGroupThatIsPartOfTheNameStays() {
        #expect(AlbumEdition.split("Songs (for Strings)") == ("Songs (for Strings)", nil))
        #expect(AlbumEdition.split("(Nothing) Left Over") == ("(Nothing) Left Over", nil))
        #expect(AlbumEdition.split("Harborhead") == ("Harborhead", nil))
    }

    @Test func aNameThatIsOnlyTheGroupKeepsIt() {
        #expect(AlbumEdition.split("(Live)") == ("(Live)", nil))
    }
}
