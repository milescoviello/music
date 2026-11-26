import Foundation
import Testing
@testable import MusicLogic

@Suite("Car navigation")
struct RemoteCarNavTests {
    @Test func turnsFromBearings() {
        #expect(RemoteCarTurn.turn(from: 0, to: 10) == 0)
        #expect(RemoteCarTurn.turn(from: 0, to: 30) == 1)
        #expect(RemoteCarTurn.turn(from: 0, to: 330) == -1)
        #expect(RemoteCarTurn.turn(from: 0, to: 90) == 2)
        #expect(RemoteCarTurn.turn(from: 350, to: 80) == 2)          // across north
        #expect(RemoteCarTurn.turn(from: 0, to: 270) == -2)
        #expect(RemoteCarTurn.turn(from: 0, to: 150) == 3)
        #expect(RemoteCarTurn.turn(from: 0, to: 178) == RemoteCarTurn.uTurn)
    }

    @Test func streetFromInstruction() {
        #expect(RemoteCarTurn.street(from: "Turn right onto Arlington Street") == "Arlington Street")
        #expect(RemoteCarTurn.street(from: "Continue on I-90 E.") == "I-90 E")
        #expect(RemoteCarTurn.street(from: "Take exit 22 toward Boston") == "Boston")
        #expect(RemoteCarTurn.street(from: "Make a U-turn") == "Make a U-turn")
    }

    @Test func thinsALine() {
        let straight: [[Double]] = (0...100).map { (i: Int) -> [Double] in [42.0 + Double(i) * 0.0001, -71.0] }
        #expect(RemoteCarPolyline.simplify(straight, tolerance: 3).count == 2)
        let up: [[Double]] = (0...50).map { (i: Int) -> [Double] in [42.0 + Double(i) * 0.0001, -71.0] }
        let across: [[Double]] = (1...50).map { (i: Int) -> [Double] in [42.005, -71.0 + Double(i) * 0.0001] }
        let corner: [[Double]] = up + across
        let kept = RemoteCarPolyline.simplify(corner, tolerance: 3)
        #expect(kept.count == 3)
        #expect(kept[1] == [42.005, -71.0])
    }

    @Test func routeFromMaps() {
        // north 300 m, right turn, east 300 m
        let north: [[Double]] = (0...30).map { (i: Int) -> [Double] in [42.0 + Double(i) * 0.0001, -71.0] }
        let east: [[Double]] = (0...30).map { (i: Int) -> [Double] in [42.003, -71.0 + Double(i) * 0.00013] }
        let line: [[Double]] = north + Array(east.dropFirst())
        let steps = [
            RemoteCarRoute.MapsStep(instruction: "", points: [north[0]]),
            RemoteCarRoute.MapsStep(instruction: "Head north on Main Street", points: north),
            RemoteCarRoute.MapsStep(instruction: "Turn right onto Elm Street", points: east),
            RemoteCarRoute.MapsStep(instruction: "Arrive at the library", points: [east.last!]),
        ]
        let route = RemoteCarRoute.from(points: line, steps: steps, distance: 620, time: 90,
                                        destination: "Library", new: true)
        #expect(route.steps.count == 3)                              // the empty start step is dropped
        #expect(route.steps[1].turn == 2)
        #expect(route.steps[1].street == "Elm Street")
        #expect(route.steps[2].turn == RemoteCarTurn.arrive)
        #expect(route.steps[2].street == "Library")
        #expect(route.points.count == 3)                             // two straight stretches: their ends
        #expect(route.new)
    }

    @Test func recentsDedupeAndCap() {
        let a = RemoteCarPlace(id: "a", title: "A", subtitle: "", lat: 42, lon: -71, usedAt: .now)
        let near = RemoteCarPlace(id: "b", title: "A again", subtitle: "", lat: 42.0002, lon: -71, usedAt: .now)
        var list = RemoteCarPlace.remember(a, in: [])
        list = RemoteCarPlace.remember(near, in: list)
        #expect(list.map(\.id) == ["b"])
        for i in 0..<20 {
            list = RemoteCarPlace.remember(RemoteCarPlace(id: "\(i)", title: "", subtitle: "", lat: 40 + Double(i), lon: -71, usedAt: .now), in: list)
        }
        #expect(list.count == 12)
        #expect(list.first?.id == "19")
    }

    @Test func encodesWhatTheCarReads() throws {
        let route = RemoteCarRoute(destination: "X", distance: 10, time: 5, points: [[42, -71], [42.1, -71]],
                                   steps: [.init(lat: 42.1, lon: -71, text: "Arrive", street: "X", turn: 5)], new: false)
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(route)) as? [String: Any]
        #expect(object?["destination"] as? String == "X")
        #expect((object?["points"] as? [[Double]])?.count == 2)
        #expect(object?["new"] as? Bool == false)
        let step = (object?["steps"] as? [[String: Any]])?.first
        #expect(step?["turn"] as? Int == 5)
        #expect(step?["street"] as? String == "X")
    }
}
