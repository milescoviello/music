import Foundation

// Turn-by-turn for the car (`RemoteControl`, "The car."). The phone works out the route with
// Apple Maps and sends it; the car draws its own map, follows the route, and asks for a new
// one if the driver leaves it. Everything here is plain data and arithmetic, shared with the
// desktop (which serves no navigation) and tested on Linux.

/// A route as the car takes it (the car's `map/nav.h`).
struct RemoteCarRoute: Codable, Equatable, Sendable {
    struct Step: Codable, Equatable, Sendable {
        var lat: Double
        var lon: Double
        /// What to do there, as Maps says it: "Turn right onto Arlington Street".
        var text: String
        /// The road it leads onto, for the big line on the car's screen.
        var street: String
        /// -3 sharp left ... 0 straight ... 3 sharp right, 4 U-turn, 5 arrive (`RemoteCarTurn`).
        var turn: Int
    }

    var destination: String
    /// Metres and seconds, as planned.
    var distance: Double
    var time: Double
    /// `[latitude, longitude]` pairs along the road.
    var points: [[Double]]
    var steps: [Step]
    /// True for a route the driver just asked for, which brings the car's map up; false for
    /// a new route to the same place after leaving the old one.
    var new: Bool
}

/// The places the car offers on its Destination page: recent and saved destinations.
struct RemoteCarPlaces: Codable, Equatable, Sendable {
    struct Item: Codable, Equatable, Sendable {
        var id: String
        var title: String
        var subtitle: String
    }

    var items: [Item]
}

/// Where the car is when it asks for a new route.
struct RemoteCarReroute: Codable, Equatable, Sendable {
    var lat: Double
    var lon: Double
    var heading: Double?
}

/// A place remembered for the car: what it was called and where.
struct RemoteCarPlace: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var subtitle: String
    var lat: Double
    var lon: Double
    var usedAt: Date

    /// Recents, newest first, without repeats (a place is the same if it is within 50 m),
    /// at most `limit`.
    static func remember(_ place: RemoteCarPlace, in list: [RemoteCarPlace], limit: Int = 12) -> [RemoteCarPlace] {
        let others = list.filter { RemoteCarGeo.metres(($0.lat, $0.lon), (place.lat, place.lon)) > 50 }
        return Array(([place] + others).prefix(limit))
    }
}

/// What a step does, from the road's direction before and after it.
enum RemoteCarTurn {
    static let arrive = 5
    static let uTurn = 4

    /// The change of bearing (degrees, either way round) as a turn: under 20 straight, under
    /// 50 slight, under 135 a turn, under 170 sharp, beyond that a U-turn.
    static func turn(from before: Double, to after: Double) -> Int {
        let change = (after - before + 540).truncatingRemainder(dividingBy: 360) - 180
        let size = abs(change)
        let side = change > 0 ? 1 : -1
        switch size {
        case ..<20: return 0
        case ..<50: return side
        case ..<135: return 2 * side
        case ..<170: return 3 * side
        default: return uTurn
        }
    }

    /// The road a Maps instruction leads onto: what follows "onto", "on", "toward" or
    /// "to"; failing that, the whole instruction.
    static func street(from instruction: String) -> String {
        for word in [" onto ", " on ", " toward ", " to "] {
            if let range = instruction.range(of: word, options: .caseInsensitive) {
                let rest = instruction[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                if !rest.isEmpty { return rest.hasSuffix(".") ? String(rest.dropLast()) : rest }
            }
        }
        return instruction
    }
}

/// Distances and bearings on the earth, near enough for roads.
enum RemoteCarGeo {
    static func metres(_ a: (Double, Double), _ b: (Double, Double)) -> Double {
        let k = cos(a.0 * .pi / 180)
        return hypot((b.0 - a.0) * 111_320, (b.1 - a.1) * 111_320 * k)
    }

    /// Degrees from north, clockwise.
    static func bearing(_ a: (Double, Double), _ b: (Double, Double)) -> Double {
        let k = cos(a.0 * .pi / 180)
        let degrees = atan2((b.1 - a.1) * k, b.0 - a.0) * 180 / .pi
        return (degrees + 360).truncatingRemainder(dividingBy: 360)
    }
}

/// Fewer points for the same line: a long drive from Maps has tens of thousands, the car's
/// Wi-Fi is slow, and a road drawn within a few metres looks the same.
enum RemoteCarPolyline {
    /// Douglas–Peucker, tolerance in metres. Keeps the ends.
    static func simplify(_ points: [[Double]], tolerance: Double) -> [[Double]] {
        guard points.count > 2 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        var stack = [(0, points.count - 1)]
        while let (first, last) = stack.popLast() {
            var worst = 0.0
            var at = -1
            for i in (first + 1)..<last {
                let d = offLine(points[i], points[first], points[last])
                if d > worst { worst = d; at = i }
            }
            if at > 0, worst > tolerance {
                keep[at] = true
                stack.append((first, at))
                stack.append((at, last))
            }
        }
        return points.indices.filter { keep[$0] }.map { points[$0] }
    }

    /// Metres from p to the segment a–b, on a flat patch around a.
    static func offLine(_ p: [Double], _ a: [Double], _ b: [Double]) -> Double {
        let k = cos(a[0] * .pi / 180) * 111_320
        let (px, py) = ((p[1] - a[1]) * k, (p[0] - a[0]) * 111_320)
        let (bx, by) = ((b[1] - a[1]) * k, (b[0] - a[0]) * 111_320)
        let length2 = bx * bx + by * by
        let t = length2 > 0 ? max(0, min(1, (px * bx + py * by) / length2)) : 0
        return hypot(px - t * bx, py - t * by)
    }
}

extension RemoteCarRoute {
    /// One step of Maps' answer: what it says, and its stretch of road.
    struct MapsStep: Sendable {
        var instruction: String
        var points: [[Double]]
    }

    /// The car's route from Maps' answer: the line thinned to within 3 m, a step wherever
    /// Maps says something, each step's turn read off the road's bearing just before and
    /// just after it, and the last step the arrival.
    static func from(points: [[Double]], steps: [MapsStep], distance: Double, time: Double,
                     destination: String, new: Bool) -> RemoteCarRoute {
        var out: [Step] = []
        let said = steps.indices.filter { !steps[$0].instruction.isEmpty && !steps[$0].points.isEmpty }
        for (n, i) in said.enumerated() {
            let step = steps[i]
            let start = step.points[0]
            let last = n == said.count - 1
            var turn = RemoteCarTurn.arrive
            if !last {
                let before = i > 0 ? tail(of: steps[i - 1].points, metres: 15) : nil
                let after = head(of: step.points, metres: 15)
                if let before, let after {
                    turn = RemoteCarTurn.turn(from: RemoteCarGeo.bearing((before[0][0], before[0][1]), (before[1][0], before[1][1])),
                                              to: RemoteCarGeo.bearing((after[0][0], after[0][1]), (after[1][0], after[1][1])))
                } else {
                    turn = 0
                }
            }
            out.append(Step(lat: start[0], lon: start[1], text: step.instruction,
                            street: last ? destination : RemoteCarTurn.street(from: step.instruction), turn: turn))
        }
        return RemoteCarRoute(destination: destination, distance: distance, time: time,
                              points: RemoteCarPolyline.simplify(points, tolerance: 3), steps: out, new: new)
    }

    /// The first point and the one about `metres` along: the direction a stretch sets off in.
    private static func head(of points: [[Double]], metres: Double) -> [[Double]]? {
        guard points.count > 1 else { return nil }
        var along = 0.0
        for i in 1..<points.count {
            along += RemoteCarGeo.metres((points[i - 1][0], points[i - 1][1]), (points[i][0], points[i][1]))
            if along >= metres || i == points.count - 1 { return [points[0], points[i]] }
        }
        return nil
    }

    /// The point about `metres` before the end, and the end: the direction a stretch arrives in.
    private static func tail(of points: [[Double]], metres: Double) -> [[Double]]? {
        guard points.count > 1 else { return nil }
        var along = 0.0
        for i in stride(from: points.count - 2, through: 0, by: -1) {
            along += RemoteCarGeo.metres((points[i][0], points[i][1]), (points[i + 1][0], points[i + 1][1]))
            if along >= metres || i == 0 { return [points[i], points[points.count - 1]] }
        }
        return nil
    }
}

/// Navigation for the car: the iPhone has one (`CarNavigation`), routing with Apple Maps from
/// where the phone is. The desktop has none, and the car's navigation routes answer 404.
@MainActor
protocol RemoteCarNavigator: AnyObject {
    /// The route being followed, if any.
    var route: RemoteCarRoute? { get }
    func places() -> RemoteCarPlaces
    /// Starts navigating to one of `places()`; false if there is no such place or no route.
    func navigate(toPlace id: String) async -> Bool
    /// The car has left the route: a new one to the same place, from here.
    func reroute(from: RemoteCarReroute) async
    func stop()
}
