import Foundation
import Testing
@testable import MusicLogic

@Suite("Car position")
struct RemoteCarLocationTests {
    private func object(_ location: RemoteCarLocation) throws -> [String: Any] {
        let data = try JSONEncoder().encode(location)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// The car's `gps_phone` reads exactly these keys; speed and course are negative when unknown.
    @Test func encodesTheCarsShape() throws {
        let fix = RemoteCarLocation(lat: 42.3522, lon: -71.0656, alt: 12.5, speed: 11.2, course: 268.0,
                                    acc: 5, t: 1_764_170_000.5)
        let o = try object(fix)
        #expect(Set(o.keys) == ["lat", "lon", "alt", "speed", "course", "acc", "t"])
        #expect(o["lat"] as? Double == 42.3522)
        #expect(o["speed"] as? Double == 11.2)
        #expect(o["t"] as? Double == 1_764_170_000.5)
    }

    /// No vertical fix: altitude is left out, so the car keeps its own (it reads a missing key as unknown).
    @Test func leavesOutAnUnknownAltitude() throws {
        let fix = RemoteCarLocation(lat: 42, lon: -71, alt: nil, speed: -1, course: -1, acc: 8, t: 1)
        let o = try object(fix)
        #expect(o["alt"] == nil)
        #expect(o["speed"] as? Double == -1)
        #expect(o["course"] as? Double == -1)
    }

    @Test func refusesVagueOrImpossibleFixes() {
        var fix = RemoteCarLocation(lat: 42, lon: -71, alt: nil, speed: 0, course: -1, acc: 30, t: 1)
        #expect(fix.usable)
        fix.acc = 100
        #expect(fix.usable)
        fix.acc = 101                       // a cell-tower guess: would put the car on the wrong street
        #expect(!fix.usable)
        fix.acc = -1                        // Core Location's "invalid"
        #expect(!fix.usable)
        fix.acc = 5
        fix.lat = 91
        #expect(!fix.usable)
        fix.lat = 42
        fix.lon = -181
        #expect(!fix.usable)
    }

    @Test func pacesToAboutOncePerSecond() {
        var pacer = RemoteCarLocationPacer(interval: 0.9)
        var sent: [Bool] = []
        for t in [100.0, 100.3, 100.89, 100.9, 102.0] { sent.append(pacer.shouldSend(at: t)) }
        #expect(sent == [true, false, false, true, true])
        pacer.reset()                       // a new car connection sends its first fix at once
        let first = pacer.shouldSend(at: 102.1)
        #expect(first)
    }

    /// Only the car is sent the phone's position, never another paired device following the music.
    @Test func knowsACarByItsUserAgent() {
        #expect(RemoteCarLocation.isCar(userAgent: "AudiMMI/1"))
        #expect(!RemoteCarLocation.isCar(userAgent: "Music/1.0 (Linux)"))
        #expect(!RemoteCarLocation.isCar(userAgent: "AudiMMI"))
        #expect(!RemoteCarLocation.isCar(userAgent: nil))
    }
}
