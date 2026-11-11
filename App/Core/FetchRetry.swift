import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// When a song the cache could not fetch is tried again.
///
/// A fetch that failed used to be given up on until the app restarted, which is right for
/// a song the server refuses and wrong for a connection that dropped: a quarter of an hour
/// of a flaky tunnel left ten songs in a row uncached for the rest of the day, and each
/// then streamed over that same connection when its turn came. Those failures are tried
/// again, half a minute later at first and less often each time, up to every ten minutes.
/// A refusal is still final.
struct FetchRetry: Sendable {
    private struct Waiting: Sendable {
        var failures: Int
        var notBefore: Date
    }

    private var waiting: [String: Waiting] = [:]

    static let firstDelay: TimeInterval = 30
    static let longestDelay: TimeInterval = 600

    /// A dropped or timed-out connection, or no route to the server: worth another try.
    /// By code, not by name, as Linux's Foundation does not name all of them.
    static func isTransient(_ error: any Error) -> Bool {
        let code = (error as? URLError)?.code.rawValue ?? (error as NSError).code
        guard (error as? URLError) != nil || (error as NSError).domain == NSURLErrorDomain else { return false }
        return transientCodes.contains(code)
    }

    private static let transientCodes: Set<Int> = [
        -1001, // timed out
        -1003, // cannot find host
        -1004, // cannot connect to host
        -1005, // network connection lost
        -1006, // DNS lookup failed
        -1009, // not connected to the internet
        -1018, // international roaming off
        -1019, // call is active
        -1020, // data not allowed
        -1200, // secure connection failed
    ]

    /// Seconds to wait after this many failures in a row.
    static func delay(afterFailures failures: Int) -> TimeInterval {
        min(firstDelay * pow(2, Double(max(0, failures - 1))), longestDelay)
    }

    /// Records a failure, and returns how long until the song may be tried again.
    @discardableResult
    mutating func failed(_ songID: String, at now: Date = .now) -> TimeInterval {
        let failures = (waiting[songID]?.failures ?? 0) + 1
        let delay = Self.delay(afterFailures: failures)
        waiting[songID] = Waiting(failures: failures, notBefore: now.addingTimeInterval(delay))
        return delay
    }

    mutating func succeeded(_ songID: String) {
        waiting[songID] = nil
    }

    func isWaiting(_ songID: String, at now: Date = .now) -> Bool {
        guard let entry = waiting[songID] else { return false }
        return entry.notBefore > now
    }

    /// The soonest any of `songIDs` may be tried again, if any of them is waiting.
    func nextTry(among songIDs: some Sequence<String>, after now: Date = .now) -> Date? {
        songIDs.compactMap { waiting[$0]?.notBefore }.filter { $0 > now }.min()
    }

    /// The network came back: everything waiting may go now, though a song that keeps
    /// failing still waits longer after its next failure.
    mutating func networkReturned(at now: Date = .now) {
        for key in waiting.keys { waiting[key]?.notBefore = now }
    }
}

/// Lookups made by the dozen in the background -- a mix's songs, a radio's hundred and
/// fifty candidates -- a few at a time.
///
/// All at once, they filled the connections to the server. Building the day's mixes on
/// 2026-11-08 sent 155 song lookups in a second; each took four seconds to answer, and
/// what was tapped meanwhile queued behind them: a playlist took 3.5 s to open and a
/// search as long. A few at a time leaves room for what is waited on.
actor RequestLane {
    /// For the mixes and the sonic radios: three of the six connections to the server.
    static let background = RequestLane(limit: 3)

    private let limit: Int
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    /// Runs `work` once one of the lane's places is free.
    func run<T: Sendable>(_ work: @Sendable () async -> T) async -> T {
        if running < limit {
            running += 1
        } else {
            await withCheckedContinuation { waiting.append($0) }
        }
        let result = await work()
        // The place passes straight to whoever waited longest.
        if waiting.isEmpty {
            running -= 1
        } else {
            waiting.removeFirst().resume()
        }
        return result
    }
}
