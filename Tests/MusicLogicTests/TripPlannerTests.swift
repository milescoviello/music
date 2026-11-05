import Foundation
import Testing

@testable import MusicLogic

/// Trip mode's whole claim is a number: this much music, this much space, this much of it
/// already here. If the arithmetic is wrong the feature is worse than useless, because
/// someone finds out on a plane.
struct TripPlannerTests {
    private func song(_ id: String, minutes: Int = 5, title: String? = nil, artist: String = "Artist") -> Song {
        var song = Song(id: id, title: title ?? "Track \(id)")
        song.artist = artist
        song.duration = minutes * 60
        song.size = Int64(minutes * 60 * 1_000_000)
        return song
    }

    private func group(_ id: String, songs: [Song]) -> TripPlanner.Group {
        TripPlanner.Group(id: id, name: "Album \(id)", songs: songs)
    }

    @Test func aTripIsDaysTimesHours() {
        #expect(TripPlanner.targetSeconds(days: 5, hoursPerDay: 3) == 54_000)
        #expect(TripPlanner.targetSeconds(days: -1, hoursPerDay: 3) == 0)
    }

    @Test func planningStopsOnceTheTargetIsCovered() {
        let groups = (0..<10).map { index in
            group("g\(index)", songs: (0..<6).map { song("s\(index)-\($0)") })
        }
        let plan = TripPlanner.plan(
            groups: groups,
            downloaded: [],
            targetSeconds: 3_600,
            quality: .standard,
            freeBytes: 100_000_000_000
        )
        // 30 minutes per group, so two cover an hour and the rest are not queued.
        #expect(plan.groups.count == 2)
        #expect(plan.seconds >= 3_600)
    }

    /// The most reassuring number on the screen: most trips are half-planned already.
    @Test func whatIsAlreadyOnThePhoneComesFirstAndCostsNothing() {
        let here = group("here", songs: (0..<6).map { song("here\($0)") })
        let away = group("away", songs: (0..<6).map { song("away\($0)") })

        let plan = TripPlanner.plan(
            groups: [away, here],
            downloaded: Set(here.songs.map(\.id)),
            targetSeconds: 1_800,
            quality: .original,
            freeBytes: 100_000_000_000
        )

        #expect(plan.groups.first?.id == "here")
        #expect(plan.toDownload.isEmpty)
        #expect(plan.alreadyCount == 6)
        #expect(plan.bytesToDownload == 0)
    }

    @Test func aGroupThatWillNotFitIsSkippedNotTruncated() {
        let big = group("big", songs: (0..<20).map { song("big\($0)", minutes: 10) })
        let small = group("small", songs: [song("small0", minutes: 4)])

        let plan = TripPlanner.plan(
            groups: [big, small],
            downloaded: [],
            targetSeconds: 36_000,
            quality: .original,
            // Enough for the small group only, once the reserve is taken off.
            freeBytes: 2_500_000_000
        )

        #expect(plan.groups.map(\.id) == ["small"])
        // Said plainly, because "we quietly gave you less" is the failure mode here.
        #expect(plan.isSpaceLimited)
    }

    @Test func theReserveIsNeverSpent() {
        let plan = TripPlanner.plan(
            groups: [group("g", songs: [song("s", minutes: 5)])],
            downloaded: [],
            targetSeconds: 3_600,
            quality: .original,
            freeBytes: TripPlanner.reserveBytes
        )
        #expect(plan.groups.isEmpty)
        #expect(plan.isSpaceLimited)
    }

    /// The two overlapping music folders mean the same record can appear twice under
    /// different ids, and downloading both is the worst possible use of the space this
    /// screen exists to save.
    @Test func theSameRecordingIsNotPackedTwice() {
        let first = group("a", songs: [song("id1", title: "Paper Lanterns", artist: "Mira Vale")])
        let second = group("b", songs: [song("id2", title: "paper lanterns", artist: "mira vale")])

        let plan = TripPlanner.plan(
            groups: [first, second],
            downloaded: [],
            targetSeconds: 36_000,
            quality: .standard,
            freeBytes: 100_000_000_000
        )
        #expect(plan.songCount == 1)
    }

    @Test func qualityIsWhatMakesTheTripFitAtAll() {
        let groups = (0..<40).map { index in
            group("g\(index)", songs: (0..<10).map { song("s\(index)-\($0)", minutes: 5) })
        }
        let target = TripPlanner.targetSeconds(days: 5, hoursPerDay: 3)

        let lossless = TripPlanner.plan(
            groups: groups, downloaded: [], targetSeconds: target,
            quality: .original, freeBytes: 100_000_000_000
        )
        let transcoded = TripPlanner.plan(
            groups: groups, downloaded: [], targetSeconds: target,
            quality: .standard, freeBytes: 100_000_000_000
        )

        // Same music, an order of magnitude apart -- 54 GB against under 2 GB.
        #expect(lossless.bytesToDownload > 50_000_000_000)
        #expect(transcoded.bytesToDownload < 2_000_000_000)
    }
}
