import Foundation
import Testing

@testable import MusicLogic

/// The searches that found nothing on this server, put right before they are sent.
struct SearchVocabularyTests {
    private let vocabulary = SearchVocabulary.build(names: [
        "Q.", "Silhouettes Over Water", "Lampwick", "Mara Q.", "RX/TX", "MIRÉLA",
        "Pale Orchid", "Iron Meadow", "Harborhead", "Field B", "Won’t Settle", "Paper Gulls",
    ])

    /// The one that was reported: "q" finds nothing on the server, "Q." finds the song.
    @Test func aSingleLetterTakesTheLibrarysSpelling() {
        #expect(vocabulary.correction(for: "q") == "Q.")
        #expect(vocabulary.correction(for: "Q") == "Q.")
    }

    @Test func punctuationAndAccentsTakeTheLibrarysSpelling() {
        #expect(vocabulary.correction(for: "rxtx") == "RX/TX")
        #expect(vocabulary.correction(for: "mirela") == "MIRÉLA")
        #expect(vocabulary.correction(for: "wont settle") == "Won’t settle")
    }

    @Test func misspelledWordsTakeTheClosestOne() {
        #expect(vocabulary.correction(for: "silhouets over water") == "Silhouettes over water")
        #expect(vocabulary.correction(for: "harborhed") == "Harborhead")
        // Two neighbours swapped is one edit.
        #expect(vocabulary.correction(for: "pale orhcid") == "pale Orchid")
    }

    @Test func wordsRunTogetherAreSplit() {
        #expect(vocabulary.correction(for: "paleorchid") == "Pale Orchid")
        #expect(vocabulary.correction(for: "ironmeadow") == "Iron Meadow")
    }

    /// The start of a word is left alone: it is still being typed, and the server matches
    /// starts. A slip is put right once the word is whole.
    @Test func theWordBeingTypedIsLeftAlone() {
        #expect(vocabulary.correction(for: "harborh") == nil)
        #expect(vocabulary.correction(for: "silhouettes ov") == nil)
        #expect(vocabulary.correction(for: "harbrohead") == "Harborhead")
    }

    /// Each kind of slip here went wrong on the real library before the order was changed:
    /// a one-letter slip split into two words, a commoner word that lacks a typed letter,
    /// a word matched by how it starts.
    @Test func theCasesTheRealLibraryGotWrong() {
        let library = SearchVocabulary.build(names: [
            "Harborhead", "Harbor", "Hed", "Mellori Band", "(ME", "Lori", "Wren Keilor",
            "Kelos", "Kelos", "Kelos", "Iris Calder", "Calders", "Calders", "Maya Drift",
            "Driven", "Driven", "Nerivale", "Holt Vane", "Vane", "Vine",
        ])
        #expect(library.correction(for: "harborhed") == "Harborhead")
        #expect(library.correction(for: "melori band") == "Mellori band")
        #expect(library.correction(for: "wren kelor") == "wren Keilor")
        #expect(library.correction(for: "iris caldre") == "iris Calder")
        #expect(library.correction(for: "maya drfit") == "maya Drift")
        #expect(library.correction(for: "nerio") == nil)
        #expect(library.correction(for: "holt vne") == "holt Vane")
        // Brackets round a word are not searched for: "(Q.)" is searched as "Q.".
        #expect(SearchVocabulary.build(names: ["Song (Q.)"]).correction(for: "q") == "Q.")
    }

    @Test func whatTheLibraryAlreadySaysIsNotTouched() {
        #expect(vocabulary.correction(for: "Harborhead") == nil)
        #expect(vocabulary.correction(for: "harborhead") == nil)
        #expect(vocabulary.correction(for: "field b") == nil)
    }

    /// Too short to guess from, and words nowhere in the library -- a half-remembered
    /// lyric -- are sent as they are.
    @Test func shortOrUnknownWordsAreNotGuessed() {
        #expect(vocabulary.correction(for: "xyz") == nil)
        #expect(vocabulary.correction(for: "zzzzzzzzzz") == nil)
        #expect(SearchVocabulary().correction(for: "harborhed") == nil)
    }

    @Test func editDistance() {
        func d(_ a: String, _ b: String, _ limit: Int = 2) -> Int? {
            SearchVocabulary.distance(Array(a.unicodeScalars), Array(b.unicodeScalars), limit: limit)
        }
        #expect(d("orchid", "orchid") == 0)
        #expect(d("orhcid", "orchid") == 1)
        #expect(d("silhouets", "silhouettes") == 2)
        #expect(d("abc", "xyz") == nil)
        #expect(d("harbroh", "harborhead") == nil)
    }

    @Test func survivesBeingSaved() throws {
        let data = try JSONEncoder().encode(vocabulary)
        let decoded = try JSONDecoder().decode(SearchVocabulary.self, from: data)
        #expect(decoded == vocabulary)
        #expect(decoded.correction(for: "q") == "Q.")
    }
}

struct SearchArrangingTests {
    /// `search3` listed titles that merely contain "Q." above the song actually called "Q.".
    @Test func theExactTitleComesFirst() {
        var results = SearchResult3()
        results.song = [
            Song(id: "1", title: "A.B.Q."), Song(id: "2", title: "Thank You, Q."),
            Song(id: "3", title: "Q.T. Girl"), Song(id: "4", title: "Q."),
        ]
        let arranged = SearchRanking.arranged(results, for: "q")
        #expect(arranged.songs.map(\.id) == ["4", "3", "1", "2"])
        guard case let .song(top) = SearchRanking.topResult(for: "q", in: arranged) else {
            Issue.record("expected a song"); return
        }
        #expect(top.id == "4")
    }

    /// The library's two folders overlap, so "All" found most songs twice.
    @Test func oneCopyOfEachRecording() {
        var first = Song(id: "a", title: "Nineteen Lanterns")
        first.artist = "Paper Gulls"
        var second = Song(id: "b", title: "Nineteen Lanterns")
        second.artist = "Paper Gulls"
        var other = Song(id: "c", title: "Nineteen Lanterns")
        other.artist = "Someone Else"
        var results = SearchResult3()
        results.song = [first, second, other]
        #expect(SearchRanking.arranged(results, for: "lanterns").songs.map(\.id) == ["a", "c"])
    }

    /// The two folders hold many albums twice; every album list shows one of each, the
    /// first kept, and keeps different artists' albums of the same name apart.
    @Test func oneOfEachAlbum() {
        var a1 = Album(id: "1", name: "Tidewater"); a1.artist = "Pale Orchid"
        var a2 = Album(id: "2", name: "Tidewater"); a2.artist = "Pale Orchid"
        var other = Album(id: "3", name: "Tidewater"); other.artist = "Someone Else"
        var singles = Album(id: "4", name: "Singles"); singles.artist = "A"
        var singles2 = Album(id: "5", name: "Singles"); singles2.artist = "B"
        #expect(SearchRanking.oneOfEach([a1, a2, other, singles, singles2]).map(\.id) == ["1", "3", "4", "5"])
    }

    @Test func addingKeepsTheTypedResultsFirstAndDropsRepeats() {
        var typed = SearchResult3()
        typed.song = [Song(id: "1", title: "One")]
        var corrected = SearchResult3()
        corrected.song = [Song(id: "2", title: "Two"), Song(id: "1", title: "One")]
        #expect(typed.adding(corrected).songs.map(\.id) == ["1", "2"])
    }
}
