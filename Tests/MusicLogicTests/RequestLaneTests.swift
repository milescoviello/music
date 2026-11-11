import Foundation
import Testing
@testable import MusicLogic

@Suite("Request lane")
struct RequestLaneTests {
    /// Counts what is running at once, and the most there ever were.
    actor Gauge {
        private(set) var now = 0
        private(set) var most = 0
        func enter() { now += 1; most = max(most, now) }
        func leave() { now -= 1 }
    }

    @Test func neverMoreThanItsLimitAtOnce() async {
        let lane = RequestLane(limit: 3)
        let gauge = Gauge()
        let answers = await withTaskGroup(of: Int.self) { group in
            for index in 0..<40 {
                group.addTask {
                    await lane.run {
                        await gauge.enter()
                        try? await Task.sleep(for: .milliseconds(2))
                        await gauge.leave()
                        return index
                    }
                }
            }
            var all: [Int] = []
            for await answer in group { all.append(answer) }
            return all
        }
        #expect(answers.sorted() == Array(0..<40))
        #expect(await gauge.most == 3)
        #expect(await gauge.now == 0)
    }

    @Test func aFreeLaneRunsAtOnce() async {
        let lane = RequestLane(limit: 1)
        let first = await lane.run { 1 }
        let second = await lane.run { 2 }
        #expect(first + second == 3)
    }
}
