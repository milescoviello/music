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

    /// The direct reading is the formatter's, to the millisecond: offsets either way, leap
    /// days, the turn of a year, and the first moments of 1970.
    @Test func theDirectReadingAgreesWithTheFormatter() {
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for text in [
            "2024-02-29T23:59:59.999Z", "2025-12-31T23:30:00-01:00", "2026-01-01T00:00:00+05:30",
            "1970-01-01T00:00:00.001Z", "2000-03-01T12:00:00.5+14:00", "2026-10-31T19:02:17.123456789-07:00",
        ] {
            let direct = ServerDate.rfc3339(text)?.timeIntervalSince1970
            let expected = (plain.date(from: text) ?? fractional.date(from: ServerDate.milliseconds(text)))?.timeIntervalSince1970
            #expect(direct != nil, "\(text)")
            #expect(abs((direct ?? 0) - (expected ?? -1)) < 0.0005, "\(text)")
        }
    }

    @Test func theDirectReadingTurnsDownWhatIsNotRFC3339() {
        for text in ["2026-02-30T00:00:00Z", "2026-13-01T00:00:00Z", "2026-10-31 19:02:17", "2026-10-31T19:02:17",
                     "2026-10-31T19:02:17.Z", "2026-10-31T25:02:17Z", "2026-10-31T19:02:17+0700"] {
            #expect(ServerDate.rfc3339(text) == nil, "\(text)")
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
