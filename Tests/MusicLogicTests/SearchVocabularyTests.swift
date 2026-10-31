import Foundation
import Testing

@testable import MusicLogic

/// The searches that found nothing on this server, put right before they are sent.
struct SearchVocabularyTests {
    private let vocabulary = SearchVocabulary.build(names: [
        "K.", "Cigarettes After Sex", "Apocalypse", "Greg K.", "AC/DC", "CAFUNÉ",
        "Tame Impala", "Pink Floyd", "Radiohead", "Kid A", "Don’t Stop", "Postcards",
    ])

    /// The one that was reported: "k" finds nothing on the server, "K." finds the song.
    @Test func aSingleLetterTakesTheLibrarysSpelling() {
        #expect(vocabulary.correction(for: "k") == "K.")
        #expect(vocabulary.correction(for: "K") == "K.")
    }

    @Test func punctuationAndAccentsTakeTheLibrarysSpelling() {
        #expect(vocabulary.correction(for: "acdc") == "AC/DC")
        #expect(vocabulary.correction(for: "cafune") == "CAFUNÉ")
        #expect(vocabulary.correction(for: "dont stop") == "Don’t stop")
    }

    @Test func misspelledWordsTakeTheClosestOne() {
        #expect(vocabulary.correction(for: "cigarets after sex") == "Cigarettes after sex")
        #expect(vocabulary.correction(for: "radiohed") == "Radiohead")
        // Two neighbours swapped is one edit.
        #expect(vocabulary.correction(for: "tame imapla") == "tame Impala")
    }

    @Test func wordsRunTogetherAreSplit() {
        #expect(vocabulary.correction(for: "tameimpala") == "Tame Impala")
        #expect(vocabulary.correction(for: "pinkfloyd") == "Pink Floyd")
    }

    /// The start of a word is left alone: it is still being typed, and the server matches
    /// starts. A slip is put right once the word is whole.
    @Test func theWordBeingTypedIsLeftAlone() {
        #expect(vocabulary.correction(for: "radioh") == nil)
        #expect(vocabulary.correction(for: "cigarettes aft") == nil)
        #expect(vocabulary.correction(for: "radoihead") == "Radiohead")
    }

    /// Each of these went wrong on the real library before the order was changed.
    @Test func theCasesTheRealLibraryGotWrong() {
        let library = SearchVocabulary.build(names: [
            "Radiohead", "Radio", "Hed", "Kessoku Band", "(KE", "Soku", "Billie Eilish",
            "Elise", "Elise", "Elise", "Frank Ocean", "Oceans", "Oceans", "Taylor Swift",
            "Switch", "Switch", "Clairvoyants", "Linkin Park", "Park", "Perk",
        ])
        #expect(library.correction(for: "radiohed") == "Radiohead")
        #expect(library.correction(for: "kesoku band") == "Kessoku band")
        #expect(library.correction(for: "billie elish") == "billie Eilish")
        #expect(library.correction(for: "frank ocena") == "frank Ocean")
        #expect(library.correction(for: "taylor swfit") == "taylor Swift")
        #expect(library.correction(for: "clairo") == nil)
        #expect(library.correction(for: "linkin prk") == "linkin Park")
        // Brackets round a word are not searched for: "(K.)" is searched as "K.".
        #expect(SearchVocabulary.build(names: ["Song (K.)"]).correction(for: "k") == "K.")
    }

    @Test func whatTheLibraryAlreadySaysIsNotTouched() {
        #expect(vocabulary.correction(for: "Radiohead") == nil)
        #expect(vocabulary.correction(for: "radiohead") == nil)
        #expect(vocabulary.correction(for: "kid a") == nil)
    }

    /// Too short to guess from, and words nowhere in the library -- a half-remembered
    /// lyric -- are sent as they are.
    @Test func shortOrUnknownWordsAreNotGuessed() {
        #expect(vocabulary.correction(for: "xyz") == nil)
        #expect(vocabulary.correction(for: "zzzzzzzzzz") == nil)
        #expect(SearchVocabulary().correction(for: "radiohed") == nil)
    }

    @Test func editDistance() {
        func d(_ a: String, _ b: String, _ limit: Int = 2) -> Int? {
            SearchVocabulary.distance(Array(a.unicodeScalars), Array(b.unicodeScalars), limit: limit)
        }
        #expect(d("impala", "impala") == 0)
        #expect(d("imapla", "impala") == 1)
        #expect(d("cigarets", "cigarettes") == 2)
        #expect(d("abc", "xyz") == nil)
        #expect(d("radoih", "radiohead") == nil)
    }

    @Test func survivesBeingSaved() throws {
        let data = try JSONEncoder().encode(vocabulary)
        let decoded = try JSONDecoder().decode(SearchVocabulary.self, from: data)
        #expect(decoded == vocabulary)
        #expect(decoded.correction(for: "k") == "K.")
    }
}

struct SearchArrangingTests {
    /// `search3` listed "B.B.K." and "It's O.K." above the song actually called "K.".
    @Test func theExactTitleComesFirst() {
        var results = SearchResult3()
        results.song = [
            Song(id: "1", title: "B.B.K."), Song(id: "2", title: "It's O.K."),
            Song(id: "3", title: "K.C. Girl"), Song(id: "4", title: "K."),
        ]
        let arranged = SearchRanking.arranged(results, for: "k")
        #expect(arranged.songs.map(\.id) == ["4", "3", "1", "2"])
        guard case let .song(top) = SearchRanking.topResult(for: "k", in: arranged) else {
            Issue.record("expected a song"); return
        }
        #expect(top.id == "4")
    }

    /// The library's two folders overlap, so "All" found most songs twice.
    @Test func oneCopyOfEachRecording() {
        var first = Song(id: "a", title: "Nineteen Cigarettes")
        first.artist = "Postcards"
        var second = Song(id: "b", title: "Nineteen Cigarettes")
        second.artist = "Postcards"
        var other = Song(id: "c", title: "Nineteen Cigarettes")
        other.artist = "Someone Else"
        var results = SearchResult3()
        results.song = [first, second, other]
        #expect(SearchRanking.arranged(results, for: "cigarettes").songs.map(\.id) == ["a", "c"])
    }

    @Test func addingKeepsTheTypedResultsFirstAndDropsRepeats() {
        var typed = SearchResult3()
        typed.song = [Song(id: "1", title: "One")]
        var corrected = SearchResult3()
        corrected.song = [Song(id: "2", title: "Two"), Song(id: "1", title: "One")]
        #expect(typed.adding(corrected).songs.map(\.id) == ["1", "2"])
    }
}
