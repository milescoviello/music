import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing

@testable import MusicLogic

/// A song the cache could not fetch because the connection dropped is tried again, later
/// each time; one the server refused is not.
struct FetchRetryTests {
    private let now = Date(timeIntervalSince1970: 1_793_700_000)

    @Test func aDroppedConnectionIsWorthAnotherTryAndARefusalIsNot() {
        #expect(FetchRetry.isTransient(URLError(.networkConnectionLost)))
        #expect(FetchRetry.isTransient(URLError(.timedOut)))
        #expect(FetchRetry.isTransient(URLError(.cannotConnectToHost)))
        #expect(!FetchRetry.isTransient(URLError(.badServerResponse)))
        #expect(!FetchRetry.isTransient(CocoaError(.fileWriteOutOfSpace)))
    }

    @Test func eachFailureWaitsTwiceAsLongUpToTenMinutes() {
        #expect(FetchRetry.delay(afterFailures: 1) == 30)
        #expect(FetchRetry.delay(afterFailures: 2) == 60)
        #expect(FetchRetry.delay(afterFailures: 3) == 120)
        #expect(FetchRetry.delay(afterFailures: 9) == 600)
    }

    @Test func aFailedSongWaitsThenMayGoAgain() {
        var retry = FetchRetry()
        #expect(!retry.isWaiting("a", at: now))
        retry.failed("a", at: now)
        #expect(retry.isWaiting("a", at: now.addingTimeInterval(29)))
        #expect(!retry.isWaiting("a", at: now.addingTimeInterval(31)))
        #expect(retry.nextTry(among: ["a", "b"], after: now) == now.addingTimeInterval(30))
        #expect(retry.nextTry(among: ["b"], after: now) == nil)

        retry.succeeded("a")
        #expect(!retry.isWaiting("a", at: now))
    }

    @Test func theNetworkComingBackLetsEverythingGoAtOnce() {
        var retry = FetchRetry()
        retry.failed("a", at: now)
        retry.failed("a", at: now)
        #expect(retry.isWaiting("a", at: now.addingTimeInterval(45)))
        retry.networkReturned(at: now.addingTimeInterval(5))
        #expect(!retry.isWaiting("a", at: now.addingTimeInterval(6)))
        // Its next failure still waits longer: it has failed twice already.
        let next = retry.failed("a", at: now.addingTimeInterval(6))
        #expect(next == 120)
    }
}
