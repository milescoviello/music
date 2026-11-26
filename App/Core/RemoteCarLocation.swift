import Foundation

// The phone's position for the car (`RemoteControl`, "The car."). The car's own GPS receiver
// belongs to its factory navigation (it serves one client), so while a car follows this phone
// the phone sends where it is, about once a second, as `location` events on `/v1/events`, and
// the car's map and trip recorder run on that. Plain data here, shared with the desktop (which
// has no GPS and sends none) and tested on Linux; the iPhone's side is `CarLocation`.

/// One fix as the car takes it (the car's `gps_phone`).
struct RemoteCarLocation: Codable, Equatable, Sendable {
    var lat: Double
    var lon: Double
    /// Metres above sea level; left out when the phone has no vertical fix.
    var alt: Double?
    /// Metres per second; -1 when unknown.
    var speed: Double
    /// Degrees from true north; -1 when unknown (standing still).
    var course: Double
    /// Horizontal accuracy in metres.
    var acc: Double
    /// When it was measured, Unix seconds.
    var t: Double

    /// Whether the fix is worth sending: a real position, and not so vague it would put the car
    /// on the wrong street. The car refuses anything worse than 500 m itself; 100 m here keeps
    /// cell-tower guesses off its map.
    var usable: Bool {
        (-90...90).contains(lat) && (-180...180).contains(lon) && acc >= 0 && acc <= 100
    }

    /// Whether a follower is a car: the MMI's client says `User-Agent: AudiMMI/<version>`.
    static func isCar(userAgent: String?) -> Bool {
        userAgent?.hasPrefix("AudiMMI/") == true
    }
}

/// How often fixes go out: at most `interval` apart, and a fix that arrives sooner waits for the
/// next one. Location updates can come several times a second; the car redraws per fix and wants
/// about one a second.
struct RemoteCarLocationPacer: Sendable {
    var interval: TimeInterval = 0.9
    private(set) var lastSent: TimeInterval = -.infinity

    init(interval: TimeInterval = 0.9) {
        self.interval = interval
    }

    /// True if a fix arriving at `now` (seconds, any monotonic clock) should be sent; records it.
    mutating func shouldSend(at now: TimeInterval) -> Bool {
        guard now - lastSent >= interval else { return false }
        lastSent = now
        return true
    }

    mutating func reset() {
        lastSent = -.infinity
    }
}

/// What sends this phone's position to the car. The server tells it how many cars follow; it
/// runs location updates only while there is at least one.
@MainActor
protocol RemoteCarLocating: AnyObject {
    func followersChanged(_ count: Int)
}
