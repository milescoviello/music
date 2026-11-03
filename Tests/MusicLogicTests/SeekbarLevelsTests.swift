import Foundation
import Testing
@testable import MusicLogic

/// A stand-in for the sonic service: answers per song, and a record of what was asked.
private actor Service {
    var answers: [String: Result<[Float]?, any Error>] = [:]
    private(set) var asked: [String] = []

    func answer(_ songID: String, with result: Result<[Float]?, any Error>) {
        answers[songID] = result
    }

    func levels(_ songID: String) throws -> [Float]? {
        asked.append(songID)
        return try answers[songID, default: .success(nil)].get()
    }
}

/// What the decoder throws for a reply with `NaN` in it, as the service sent for every
/// 96 kHz track: a reply that arrived, about one track, and could not be read.
let unreadableReply: any Error = DecodingError.dataCorrupted(
    .init(codingPath: [], debugDescription: "Unexpected character 'N'")
)

@MainActor
struct SeekbarLevelsTests {
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("SeekbarLevelsTests-\(UUID().uuidString)", isDirectory: true)
    private let service = Service()
    private var clock = Date(timeIntervalSince1970: 1_000_000)

    private func store(measured: [String: [Float]] = [:], at time: @escaping () -> Date) -> SeekbarLevelsStore {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = SeekbarLevelsStore(directory: directory)
        let service = service
        store.fetch = { try await service.levels($0) }
        store.measured = { measured[$0] }
        store.now = time
        return store
    }

    @Test func theServicesLevelsAreKeptForNextTime() async {
        await service.answer("a", with: .success([-20, -10]))
        let first = store { clock }
        await first.load("a")
        #expect(first.levels(for: "a") == [-20, -10])

        // A later launch reads them from Caches without asking again.
        let second = store { clock }
        await second.load("a")
        #expect(second.levels(for: "a") == [-20, -10])
        #expect(await service.asked == ["a"])
    }

    @Test func theServiceIsPreferredToTheMeasurement() async {
        await service.answer("a", with: .success([-15]))
        let store = store(measured: ["a": [-30]]) { clock }
        // Before the service has answered, the phone's own shows.
        #expect(store.levels(for: "a") == [-30])
        await store.load("a")
        #expect(store.levels(for: "a") == [-15])
    }

    @Test func aTrackNotAnalysedFallsBackAndIsAskedAgainLater() async {
        var time = clock
        let store = store(measured: ["a": [-30]]) { time }
        await store.load("a")
        #expect(store.levels(for: "a") == [-30])

        await store.load("a")
        #expect(await service.asked == ["a"])

        // Analysed since.
        await service.answer("a", with: .success([-12]))
        time += SeekbarLevelsStore.notAnalysedRetry
        await store.load("a")
        #expect(store.levels(for: "a") == [-12])
        #expect(await service.asked == ["a", "a"])
    }

    @Test func anUnreachableServiceIsLeftAloneForAWhile() async {
        var time = clock
        await service.answer("a", with: .failure(SonicError.status(503)))
        let store = store(measured: ["b": [-25]]) { time }
        await store.load("a")
        #expect(store.levels(for: "a") == nil)

        // Not asked about any track until the back-off is over; measurements still show.
        await store.load("b")
        #expect(store.levels(for: "b") == [-25])
        #expect(await service.asked == ["a"])

        await service.answer("b", with: .success([-9]))
        time += SeekbarLevelsStore.unreachableRetry
        await store.load("b")
        #expect(store.levels(for: "b") == [-9])
    }

    @Test func aReplyThatCannotBeReadHoldsBackOnlyItsOwnTrack() async {
        // What happened at 12:51 on 11-02: "Californication" answered with NaN, and
        // "All I Need", a second later, was never asked about at all.
        var time = clock
        await service.answer("californication", with: .failure(unreadableReply))
        await service.answer("all-i-need", with: .success([-11, -9]))
        let store = store { time }
        await store.load("californication")
        await store.load("all-i-need")
        #expect(store.levels(for: "all-i-need") == [-11, -9])

        // The unreadable one is asked again later, like a track not analysed yet --
        // by which time the service has analysed it again.
        await store.load("californication")
        #expect(await service.asked == ["californication", "all-i-need"])
        await service.answer("californication", with: .success([-14, -8]))
        time += SeekbarLevelsStore.notAnalysedRetry
        await store.load("californication")
        #expect(store.levels(for: "californication") == [-14, -8])
    }

    @Test func noReadingsIsNoLevels() async {
        await service.answer("a", with: .success([]))
        let store = store { clock }
        await store.load("a")
        #expect(store.levels(for: "a") == nil)
    }
}
