import Foundation
import Testing
@testable import MusicLogic

struct AutoplayTests {
    private func song(_ id: String, album: String? = nil) -> Song {
        var song = Song(id: id, title: id)
        song.albumId = album
        return song
    }

    @Test func autoplayIsOnlyOfferedForAShortQueueWithRepeatOff() {
        #expect(AutoplayRules.isActive(repeatMode: .off, upNextCount: 0, isSelfExtending: false))
        #expect(!AutoplayRules.isActive(repeatMode: .all, upNextCount: 0, isSelfExtending: false))
        #expect(!AutoplayRules.isActive(repeatMode: .off, upNextCount: 30, isSelfExtending: false))
        #expect(!AutoplayRules.isActive(repeatMode: .off, upNextCount: 2, isSelfExtending: true))
    }

    @Test func aQueueEndsWithAnAlbumWhenItsLastTwoTracksShareOne() {
        let album = PlaybackQueue.make(
            tracks: [song("a", album: "x"), song("b", album: "x")], startingAt: 0, shuffled: false, source: "X"
        )
        #expect(AutoplayRules.endsWithAlbum(album))

        let mixed = PlaybackQueue.make(
            tracks: [song("a", album: "x"), song("b", album: "y")], startingAt: 0, shuffled: false, source: "Mix"
        )
        #expect(!AutoplayRules.endsWithAlbum(mixed))

        let single = PlaybackQueue.make(tracks: [song("a", album: "x")], startingAt: 0, shuffled: false, source: "One")
        #expect(!AutoplayRules.endsWithAlbum(single))
    }

    @Test func theCarouselDependsOnHowTheQueueEnded() {
        #expect(AutoplayRules.choices(endedWithAlbum: true).contains(.nextAlbum))
        #expect(!AutoplayRules.choices(endedWithAlbum: false).contains(.nextAlbum))
        #expect(AutoplayRules.choices(endedWithAlbum: false).first == .silence)
    }

    @Test func albumDirectionPicksWhichNeighbourIsOffered() {
        let older = AutoplayRules.choices(endedWithAlbum: true, albumDirection: .previousAlbum)
        #expect(older.contains(.previousAlbum))
        #expect(!older.contains(.nextAlbum))
        #expect(AutoplayRules.defaultChoice(endedWithAlbum: true, albumDirection: .previousAlbum) == .previousAlbum)
        // A remembered "next album" falls back to what is on offer, not to silence.
        #expect(AutoplayRules.selection(preferred: .nextAlbum, available: older) == .previousAlbum)
    }

    @Test func anUnavailableChoiceFallsBackToSomethingRatherThanSilence() {
        #expect(AutoplayRules.selection(preferred: .nextAlbum, available: [.silence, .similarAlbum]) == .similarAlbum)
        #expect(AutoplayRules.selection(preferred: .silence, available: [.silence, .decade]) == .silence)
        #expect(AutoplayRules.selection(preferred: .decade, available: [.silence]) == nil)
    }

    @Test func theNextAlbumIsTheNextOneByYear() {
        func album(_ id: String, _ year: Int) -> Album {
            var album = Album(id: id, name: id)
            album.year = year
            return album
        }
        let albums = [album("c", 2001), album("a", 1995), album("b", 1997)]
        #expect(AutoplayRules.neighbour(of: "b", in: albums, direction: .nextAlbum)?.id == "c")
        #expect(AutoplayRules.neighbour(of: "b", in: albums, direction: .previousAlbum)?.id == "a")
        #expect(AutoplayRules.neighbour(of: "c", in: albums, direction: .nextAlbum) == nil)
    }

    @Test func radioAddsTwentyAndEverythingElseThirty() {
        #expect(AutoplayChoice.trackRadio.trackCount == 20)
        #expect(AutoplayChoice.nextAlbum.trackCount == 30)
        #expect(AutoplayRules.decadeStart(of: 1994) == 1990)
    }
}

struct GuestDJTests {
    private func song(_ id: String, title: String? = nil, duration: Int? = 200, rating: Int? = nil) -> Song {
        var song = Song(id: id, title: title ?? id)
        song.duration = duration
        song.userRating = rating
        return song
    }

    private func queue(_ ids: [String], at position: Int = 0) -> PlaybackQueue {
        PlaybackQueue.make(tracks: ids.map { song($0) }, startingAt: position, shuffled: false, source: "Q")
    }

    @Test func titlesAreCleanedOfTheirLastBracket() {
        #expect(GuestDJRules.cleanTitle("Song (Live)") == "song")
        #expect(GuestDJRules.cleanTitle("Song (Live) [2011 Remaster]") == "song (live)")
        #expect(GuestDJRules.cleanTitle("  Two   Words ") == "two words")
        #expect(GuestDJRules.cleanTitle("(Intro)") == "(intro)")
    }

    @Test func theSharedFiltersAreApplied() {
        let queued = [song("q", title: "Queued")]
        let candidates = [
            song("q"), // already queued
            song("v", title: "Queued (Live)"), // same song, another version
            song("short", duration: 60),
            song("long", duration: 900),
            song("bad", rating: 2),
            song("ok", rating: 3),
            song("unrated"),
            song("made"), // generated before
        ]
        let kept = GuestDJRules.filter(candidates, queue: queued, generated: ["made"]).map(\.id)
        #expect(kept == ["ok", "unrated"])
    }

    @Test func aPerTrackDJActsOnceOnEachTrackThatIsNotItsOwn() {
        let q = queue(["a", "b"])
        #expect(GuestDJRules.insertionPoint(for: .gemini, in: q, generated: [], processed: []) == 0)
        #expect(GuestDJRules.insertionPoint(for: .gemini, in: q, generated: [], processed: ["a"]) == nil)
        #expect(GuestDJRules.insertionPoint(for: .gemini, in: q, generated: ["a"], processed: []) == nil)
    }

    @Test func stretchNeedsATrackToBridgeTo() {
        #expect(GuestDJRules.insertionPoint(for: .stretch, in: queue(["a"]), generated: [], processed: []) == nil)
        #expect(GuestDJRules.insertionPoint(for: .stretch, in: queue(["a", "b"]), generated: [], processed: []) == 0)
    }

    @Test func aPoolDJKeepsTheNextTwoTracksItsOwn() {
        let q = queue(["a", "g1", "g2", "b"])
        #expect(GuestDJRules.insertionPoint(for: .freeze, in: q, generated: ["g1", "g2"], processed: []) == nil)
        #expect(GuestDJRules.insertionPoint(for: .freeze, in: q, generated: ["g1"], processed: []) == 1)
        #expect(GuestDJRules.insertionPoint(for: .freeze, in: q, generated: [], processed: []) == 0)
        // At the end of the queue it still has somewhere to put them.
        #expect(GuestDJRules.insertionPoint(for: .groupie, in: queue(["a"]), generated: [], processed: []) == 0)
    }

    @Test func aBridgeRunsFromOneTrackTowardsTheOther() {
        let outgoing = [song("o1"), song("both"), song("o2")]
        let incoming = [song("i1"), song("both")]
        let bridge = GuestDJRules.bridge(fromRelated: outgoing, toRelated: incoming, count: 3).map(\.id)
        #expect(bridge.count == 3)
        #expect(bridge.contains("both"))
        #expect(bridge.first == "o1")
        #expect(bridge.last == "i1")
    }
}

struct StationTests {
    private func song(_ id: String, year: Int? = nil, plays: Int? = nil) -> Song {
        var song = Song(id: id, title: id)
        song.year = year
        song.playCount = plays
        return song
    }

    @Test func aStationIsToppedUpWithFiveLeftAndAnAdventureNever() {
        let songs = (1...8).map { song("s\($0)") }
        var queue = PlaybackQueue.make(tracks: songs, startingAt: 0, shuffled: false, source: "R", station: .library)
        #expect(!StationRules.needsRefill(queue))
        queue.jump(toOrderIndex: 2)
        #expect(StationRules.needsRefill(queue))

        queue.station = .adventure(fromID: "a", toID: "b")
        #expect(!StationRules.needsRefill(queue))
        queue.station = nil
        #expect(!StationRules.needsRefill(queue))
    }

    @Test func aStationSurvivesBeingSaved() throws {
        let queue = PlaybackQueue.make(tracks: [song("a")], startingAt: 0, shuffled: false, source: "R", station: .decade(1990))
        let decoded = try JSONDecoder().decode(PlaybackQueue.self, from: JSONEncoder().encode(queue))
        #expect(decoded.station == .decade(1990))
    }

    @Test func deepCutsAreTheLeastPlayed() {
        let picked = StationRules.deepCuts([song("hit", plays: 40), song("never"), song("once", plays: 1), song("zero", plays: 0)], limit: 3)
        #expect(picked.map(\.id) == ["never", "zero", "once"])
    }

    @Test func timeTravelMovesForwardAndWrapsAround() {
        #expect(StationRules.nextTimeTravelSpan(after: nil, earliest: 1960, latest: 2024) == 1960...1964)
        #expect(StationRules.nextTimeTravelSpan(after: 1964, earliest: 1960, latest: 2024) == 1965...1969)
        #expect(StationRules.nextTimeTravelSpan(after: 2022, earliest: 1960, latest: 2024) == 2023...2024)
        #expect(StationRules.nextTimeTravelSpan(after: 2024, earliest: 1960, latest: 2024) == 1960...1964)
        let ordered = StationRules.chronological([song("b", year: 1999), song("x"), song("a", year: 1971)])
        #expect(ordered.map(\.id) == ["a", "b"])
    }

    @Test func freshDropsWhatIsQueuedAndRepeats() {
        let fresh = StationRules.fresh([song("a"), song("b"), song("b"), song("c")], excluding: [song("a")])
        #expect(fresh.map(\.id) == ["b", "c"])
    }

    @Test func mixesTakeOneFromEachInTurn() {
        let mixed = StationRules.interleave([[song("a1"), song("a2")], [song("b1")], [song("c1"), song("c2")]])
        #expect(mixed.map(\.id) == ["a1", "b1", "c1", "a2", "c2"])
    }

    @Test func mixTitlesNameTheirArtists() {
        #expect(Station.artistMix(ids: ["1"], names: ["Radiohead"]).title == "Radiohead Mix")
        #expect(Station.artistMix(ids: ["1", "2", "3"], names: ["A", "B", "C"]).title == "A, B & 1 More")
    }
}
