import Foundation
import Testing

@testable import MusicLogic

/// The car's side of the wire (`RemoteControl`, "The car."). The car is C on a head unit,
/// not this code, so what is pinned here is the exact text it parses.
struct RemoteCarTests {
    private func object(_ value: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func theStateComparedCarriesNoTiming() throws {
        // Timing changes every instant: on the copy compared it would make every state news.
        let state = try object(RemoteState())
        #expect(state["mediaTime"] == nil)
        #expect(state["atUptime"] == nil)
        #expect(state["rate"] == nil)
        #expect(state["outputLatency"] == nil)
    }

    @Test func theStateSentCarriesIt() throws {
        var state = RemoteState()
        state.mediaTime = 61.25
        state.atUptime = 9_000.5
        state.rate = 1
        state.outputLatency = 0.22
        let sent = try object(state)
        #expect(sent["mediaTime"] as? Double == 61.25)
        #expect(sent["atUptime"] as? Double == 9_000.5)
        #expect(sent["rate"] as? Double == 1)
        #expect(sent["outputLatency"] as? Double == 0.22)
    }

    @Test func timingDoesNotMakeAStateDiffer() {
        var timed = RemoteState()
        timed.mediaTime = 5
        // `publish` compares untimed copies; an untimed one equals itself whatever is sent.
        #expect(!RemoteState().differs(from: RemoteState(), after: 0))
        #expect(timed != RemoteState())
    }

    @Test func playItemDecodesAsTheCarSendsIt() throws {
        let typed = #"{"action": "playItem", "kind": "album", "id": "al-1", "index": 3}"#
        let command = try JSONDecoder().decode(RemoteCommand.self, from: Data(typed.utf8))
        #expect(command.action == .playItem)
        #expect(command.kind == "album")
        #expect(command.id == "al-1")
        #expect(command.index == 3)
    }

    @Test func aSpectrumEventIsOneLineTheCarCanSplit() {
        let bands = (0..<64).map { UInt8($0 * 4) }
        let event = RemoteCarSpectrum.event(mediaTime: 12.5, bands: bands, heard: 12.3, at: 400.25, rate: 1)
        #expect(event.hasPrefix("event: spectrum\ndata: "))
        #expect(event.hasSuffix("\n\n"))
        let data = event.dropFirst("event: spectrum\ndata: ".count).dropLast(2)
        let fields = data.split(separator: " ")
        #expect(fields.count == 5)
        #expect(fields[0] == "12.5000")
        #expect(fields[1].count == 128)
        #expect(fields[1].hasPrefix("0004080c"))
        #expect(fields[2] == "12.3000")
        #expect(fields[3] == "400.2500")
        #expect(fields[4] == "1.000")
    }

    @Test func aTripIdIsItsUTCStartAndNothingElse() {
        #expect(RemoteCarTrips.isValid("20261125-183000"))
        #expect(!RemoteCarTrips.isValid("20261125183000"))
        #expect(!RemoteCarTrips.isValid("../../etc/passwd"))
        #expect(!RemoteCarTrips.isValid("20261125-18300a"))
        #expect(!RemoteCarTrips.isValid(""))
    }
}
