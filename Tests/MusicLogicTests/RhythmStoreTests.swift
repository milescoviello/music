import Foundation
import Testing
@testable import MusicLogic

/// A stand-in for the sonic service: answers per song, and a record of what was asked.
private actor Service {
    var answers: [String: Result<SonicClient.Rhythm?, SonicError>] = [:]
    private(set) var asked: [String] = []

    func answer(_ songID: String, with result: Result<SonicClient.Rhythm?, SonicError>) {
        answers[songID] = result
    }

    func rhythm(_ songID: String) throws -> SonicClient.Rhythm? {
        asked.append(songID)
        return try answers[songID, default: .success(nil)].get()
    }
}

@MainActor
struct RhythmStoreTests {
    private let service = Service()
    private let clock = Date(timeIntervalSince1970: 1_000_000)

    private func store(at time: @escaping () -> Date) -> RhythmStore {
        let store = RhythmStore()
        let service = service
        store.fetch = { try await service.rhythm($0) }
        store.now = time
        return store
    }

    private func rhythm(_ id: String) -> SonicClient.Rhythm {
        SonicClient.Rhythm(
            id: id, bpm: 120, confidence: 3, beats: [0.5, 1, 1.5, 2], key: nil, scale: nil,
            keyStrength: nil, duration: 200, loudness: nil
        )
    }

    @Test func aRhythmIsAskedForOnce() async {
        await service.answer("a", with: .success(rhythm("a")))
        let store = store { clock }
        #expect(await store.load("a"))
        #expect(store.rhythm(for: "a") == rhythm("a"))

        #expect(await store.load("a") == false)
        #expect(await service.asked == ["a"])
    }

    @Test func aTrackNotAnalysedIsAskedAgainLater() async {
        var time = clock
        let store = store { time }
        #expect(await store.load("a") == false)
        #expect(store.rhythm(for: "a") == nil)

        await store.load("a")
        #expect(await service.asked == ["a"])

        // Analysed since.
        await service.answer("a", with: .success(rhythm("a")))
        time += RhythmStore.notAnalysedRetry
        #expect(await store.load("a"))
        #expect(store.rhythm(for: "a") == rhythm("a"))
    }

    @Test func anUnreachableServiceIsLeftAloneForAWhile() async {
        var time = clock
        await service.answer("a", with: .failure(.status(503)))
        let store = store { time }
        await store.load("a")

        // Not asked about any track until the back-off is over.
        await store.load("b")
        #expect(await service.asked == ["a"])

        await service.answer("b", with: .success(rhythm("b")))
        time += RhythmStore.unreachableRetry
        #expect(await store.load("b"))
    }

    @Test func onlyTheLatestTracksAreKept() async {
        let store = store { clock }
        let ids = (0...RhythmStore.capacity).map { "song\($0)" }
        for id in ids {
            await service.answer(id, with: .success(rhythm(id)))
            await store.load(id)
        }
        #expect(store.rhythm(for: ids[0]) == nil)
        #expect(store.rhythm(for: ids[1]) != nil)
        #expect(store.rhythm(for: ids[RhythmStore.capacity]) != nil)
    }

    @Test func arrivalsAreAnnounced() async {
        await service.answer("a", with: .success(rhythm("a")))
        let store = store { clock }
        let announced = await withCheckedContinuation { continuation in
            store.request(["a"]) { continuation.resume(returning: $0) }
        }
        #expect(announced == "a")
    }
}
