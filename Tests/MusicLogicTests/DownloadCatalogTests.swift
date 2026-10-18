import Foundation
import Testing

@testable import MusicLogic

/// `reconcile()` exists to survive a kill in the window between the delegate moving a
/// finished file and the catalog recording it. That window is unreachable in normal use,
/// so a test is the only way it ever gets exercised.
struct DownloadCatalogTests {
    private func song(_ id: String) -> Song {
        var song = Song(id: id, title: "Track \(id)")
        song.suffix = "flac"
        song.size = 1_000
        return song
    }

    private func entry(_ id: String, in directory: URL) -> DownloadCatalog.Entry {
        DownloadCatalog.Entry(
            song: song(id),
            filename: "\(id).flac",
            byteCount: 0,
            addedAt: .now,
            groupID: "album1",
            groupName: "Album"
        )
    }

    @Test func catalogRoundTripsThroughJSON() throws {
        var catalog = DownloadCatalog()
        catalog.entries["a"] = DownloadCatalog.Entry(
            song: song("a"), filename: "a.flac", byteCount: 2_048,
            addedAt: .now, groupID: "g", groupName: "Group"
        )

        let data = try JSONEncoder().encode(catalog)
        let restored = try JSONDecoder().decode(DownloadCatalog.self, from: data)

        #expect(restored.version == DownloadCatalog.currentVersion)
        #expect(restored.entries["a"]?.song.title == "Track a")
        #expect(restored.totalBytes == 2_048)
    }

    @Test func totalBytesIgnoresPendingEntries() {
        var catalog = DownloadCatalog()
        catalog.entries["a"] = DownloadCatalog.Entry(
            song: song("a"), filename: "a.flac", byteCount: 100, addedAt: .now,
            groupID: nil, groupName: nil
        )
        catalog.pending["b"] = DownloadCatalog.Entry(
            song: song("b"), filename: "b.flac", byteCount: 999, addedAt: .now,
            groupID: nil, groupName: nil
        )
        // Only what is actually on disk counts toward the size shown to the user.
        #expect(catalog.totalBytes == 100)
    }

    /// A version from a future build is discarded rather than half-decoded: the audio on
    /// disk is the real data and `reconcile` can re-adopt it.
    @Test func aFutureVersionIsDiscarded() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("catalog.json")
        let future = #"{"version":9999,"entries":{},"pending":{}}"#
        try Data(future.utf8).write(to: file)

        let store = DownloadCatalogStore(url: file)
        let loaded = await store.load()
        #expect(loaded.version == DownloadCatalog.currentVersion)
        #expect(loaded.entries.isEmpty)
    }

    @Test func corruptCatalogDoesNotThrowAndStartsClean() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("catalog.json")
        try Data("not json at all".utf8).write(to: file)

        let store = DownloadCatalogStore(url: file)
        let loaded = await store.load()
        #expect(loaded.entries.isEmpty)
    }

    @Test func completePromotesPendingAndRecordsTheRealSize() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = DownloadCatalogStore(url: directory.appendingPathComponent("c.json"))
        _ = await store.markPending(entry("a", in: directory))

        let after = await store.complete(songID: "a", byteCount: 4_096)
        #expect(after.pending["a"] == nil)
        #expect(after.entries["a"]?.byteCount == 4_096)
    }

    @Test func cancellingPendingLeavesNothingBehind() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = DownloadCatalogStore(url: directory.appendingPathComponent("c.json"))
        _ = await store.markPending(entry("a", in: directory))
        let after = await store.cancelPending(songID: "a")

        #expect(after.pending.isEmpty)
        #expect(after.entries.isEmpty)
    }

    @Test func completingSomethingNeverStartedIsANoOp() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = DownloadCatalogStore(url: directory.appendingPathComponent("c.json"))
        let after = await store.complete(songID: "ghost", byteCount: 10)
        #expect(after.entries.isEmpty)
    }

    /// A whole playlist is one write, so every song of it is pending the moment it lands.
    @Test func aBatchIsPendingAllAtOnce() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = DownloadCatalogStore(url: directory.appendingPathComponent("c.json"))
        let after = await store.markPending(["a", "b", "c"].map { entry($0, in: directory) })
        #expect(Set(after.pending.keys) == ["a", "b", "c"])
    }

    /// Removing one album's or playlist's download takes its own songs, here or on their
    /// way, and an album's single-song downloads — never a song another download brought.
    @Test func aGroupsDownloadIsItsOwnSongsOnly() {
        func entry(_ id: String, group: String?, album: String) -> DownloadCatalog.Entry {
            var song = song(id)
            song.albumId = album
            return DownloadCatalog.Entry(
                song: song, filename: "\(id).flac", byteCount: 1, addedAt: .now,
                groupID: group, groupName: nil
            )
        }

        var catalog = DownloadCatalog()
        catalog.entries["a"] = entry("a", group: "album1", album: "album1")
        catalog.pending["b"] = entry("b", group: "album1", album: "album1")
        // Downloaded on its own: filed in its album's folder, so part of the album.
        catalog.entries["c"] = entry("c", group: nil, album: "album1")
        // The same album's song, but it came with a playlist.
        catalog.entries["d"] = entry("d", group: "playlist1", album: "album1")
        catalog.entries["e"] = entry("e", group: "playlist1", album: "album2")

        #expect(Set(catalog.songIDs(downloadedAs: "album1")) == ["a", "b", "c"])
        #expect(Set(catalog.songIDs(downloadedAs: "playlist1")) == ["d", "e"])
        #expect(catalog.songIDs(downloadedAs: "nothing").isEmpty)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("music-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// The whole point of a quality picker is the size it saves, so the arithmetic behind that
/// promise is worth pinning — a trip plan that under-counts by a factor of eight is worse
/// than no plan.
struct DownloadQualityTests {
    private var song: Song {
        var song = Song(id: "a", title: "Let It Happen")
        song.duration = 466
        song.size = 102_063_654
        return song
    }

    @Test func originalUsesTheServersOwnFigure() {
        // Navidrome populates `size`, so this is exact rather than estimated.
        #expect(DownloadQuality.original.estimatedBytes(for: song) == 102_063_654)
    }

    @Test func transcodedRungsAreBitrateTimesDuration() {
        // 466 s at 256 kbps ≈ 14.9 MB, against 102 MB of FLAC.
        #expect(DownloadQuality.standard.estimatedBytes(for: song) == 466 * 256 * 1_000 / 8)
        #expect(DownloadQuality.standard.estimatedBytes(for: song) < 15_000_000)
    }

    @Test func aSongWithNoDurationEstimatesZeroRatherThanGuessing() {
        // Better to show nothing than to invent a number a trip plan then trusts.
        var unknown = song
        unknown.duration = nil
        #expect(DownloadQuality.high.estimatedBytes(for: unknown) == 0)
    }

    /// Every file downloaded before the picker existed has no quality key at all, and
    /// those are all originals.
    @Test func aCatalogEntryWithNoQualityReadsAsOriginal() throws {
        let legacy = Data(#"{"song":{"id":"a","title":"T"},"filename":"a.flac","byteCount":10,"addedAt":0}"#.utf8)
        let entry = try JSONDecoder().decode(DownloadCatalog.Entry.self, from: legacy)
        #expect(entry.quality == .original)
    }
}

/// Formatting is small but it is on screen constantly, and the duration helpers had
/// off-by-one potential around the minute boundary.
struct FormattingTests {
    @Test func durationsFormatAsMinutesAndSeconds() {
        #expect(0.asDuration == "0:00")
        #expect(59.asDuration == "0:59")
        #expect(60.asDuration == "1:00")
        #expect(61.asDuration == "1:01")
        #expect(3_599.asDuration == "59:59")
    }

    @Test func longDurationsReadInHoursWhenTheyShould() {
        // A 292-track playlist is hours long, and "1234:56" is not a readable figure.
        #expect(3_600.asLongDuration.isEmpty == false)
        #expect(120.asLongDuration.isEmpty == false)
    }
}
