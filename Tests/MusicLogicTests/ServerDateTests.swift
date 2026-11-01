import Foundation
import Testing

@testable import MusicLogic

/// Navidrome's dates are Go's RFC 3339, which drops trailing zeros, so a fraction of a
/// second can be any length from one digit to nine. One the parser turns down fails a
/// whole page of songs on the native API.
struct ServerDateTests {
    /// 2026-10-31 19:02:17 UTC.
    private let base = 1_793_473_337.0

    private func seconds(_ text: String) -> Double? {
        ServerDate.parse(text)?.timeIntervalSince1970
    }

    @Test func everyLengthOfFractionParses() {
        let cases: [(text: String, fraction: Double)] = [
            ("2026-10-31T19:02:17Z", 0),
            ("2026-10-31T19:02:17.7Z", 0.7),
            ("2026-10-31T19:02:17.15Z", 0.15),
            ("2026-10-31T19:02:17.123Z", 0.123),
            ("2026-10-31T19:02:17.1234Z", 0.123),
            ("2026-10-31T19:02:17.123456Z", 0.123),
            ("2026-10-31T19:02:17.123456789Z", 0.123),
            ("2026-10-31T12:02:17.5-07:00", 0.5),
            ("2026-10-31T12:02:17-07:00", 0),
        ]
        for (text, fraction) in cases {
            let parsed = seconds(text)
            #expect(parsed != nil, "\(text)")
            #expect(abs((parsed ?? 0) - (base + fraction)) < 0.001, "\(text)")
        }
    }

    @Test func somethingElseIsNoDate() {
        #expect(ServerDate.parse("yesterday") == nil)
        #expect(ServerDate.parse(nil) == nil)
    }

    @Test func onlyTheFractionIsTouched() {
        #expect(ServerDate.milliseconds("2026-10-31T19:02:17.7Z") == "2026-10-31T19:02:17.700Z")
        #expect(ServerDate.milliseconds("2026-10-31T19:02:17.123456789-07:00") == "2026-10-31T19:02:17.123-07:00")
        #expect(ServerDate.milliseconds("2026-10-31T19:02:17Z") == "2026-10-31T19:02:17Z")
    }
}
