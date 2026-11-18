import Foundation
import Testing

@testable import MusicLogic

/// Which device a press of play takes the music from (`HandoffChoice`).
struct HandoffChoiceTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func peer(_ id: String, playing: Bool = false, savedAt: Date?, count: Int = 10) -> RemoteNow {
        var state = RemoteState()
        state.isPlaying = playing
        return RemoteNow(id: id, name: id, listID: "L-\(id)", count: count, state: state, savedAt: savedAt)
    }

    @Test func aDevicePlayingIsTakenOverWhateverTheTimes() {
        let choice = HandoffChoice.choose(
            peers: [peer("phone", playing: true, savedAt: t0), peer("framework", savedAt: t0.addingTimeInterval(60))],
            serverSavedAt: t0.addingTimeInterval(120),
            localSavedAt: t0.addingTimeInterval(300)
        )
        #expect(choice == .takeOver(peer: "phone"))
    }

    @Test func aPausedDeviceListenedToMoreRecentlyIsCarriedOnFrom() {
        let choice = HandoffChoice.choose(peers: [peer("phone", savedAt: t0.addingTimeInterval(30))], serverSavedAt: nil, localSavedAt: t0)
        #expect(choice == .continueFrom(peer: "phone"))
    }

    @Test func thisDevicesOwnNewerQueueStays() {
        let choice = HandoffChoice.choose(peers: [peer("phone", savedAt: t0)], serverSavedAt: t0, localSavedAt: t0.addingTimeInterval(30))
        #expect(choice == .here)
    }

    /// Two clocks are never quite the same: half a second newer is not newer.
    @Test func aSecondsDifferenceIsNotNewer() {
        let choice = HandoffChoice.choose(peers: [peer("phone", savedAt: t0.addingTimeInterval(0.5))], serverSavedAt: nil, localSavedAt: t0)
        #expect(choice == .here)
    }

    /// Nobody answered directly: the server's queue, saved by another device since.
    @Test func theServerWhenNoDeviceAnswers() {
        #expect(HandoffChoice.choose(peers: [], serverSavedAt: t0.addingTimeInterval(20), localSavedAt: t0) == .server)
        #expect(HandoffChoice.choose(peers: [], serverSavedAt: t0.addingTimeInterval(20), localSavedAt: nil) == .server)
    }

    /// A pause reaches the server a few seconds after it happens, from the same device:
    /// the device itself has the exact place.
    @Test func theDeviceOverItsOwnSaveOnTheServer() {
        let choice = HandoffChoice.choose(
            peers: [peer("phone", savedAt: t0.addingTimeInterval(10))],
            serverSavedAt: t0.addingTimeInterval(13),
            localSavedAt: t0
        )
        #expect(choice == .continueFrom(peer: "phone"))
    }

    @Test func aDeviceWithNothingQueuedIsNoSource() {
        let choice = HandoffChoice.choose(peers: [peer("phone", playing: true, savedAt: t0, count: 0)], serverSavedAt: nil, localSavedAt: nil)
        #expect(choice == .here)
    }
}

struct PairingLinkTests {
    @Test func roundTrips() throws {
        let link = PairingLink(id: "A1-B2", name: "Miles’s Legion & co", port: 47823, addresses: ["192.168.1.20", "100.66.167.44"], key: "00ff")
        let read = try #require(PairingLink(link.url))
        #expect(read == link)
        #expect(link.url.absoluteString.hasPrefix("music-remote://pair?"))
    }

    @Test func refusesOtherLinks() {
        #expect(PairingLink(URL(string: "https://example.com/pair?id=a&k=b&a=1.2.3.4")!) == nil)
        #expect(PairingLink(URL(string: "music-remote://pair?id=a&a=1.2.3.4")!) == nil, "no key")
        #expect(PairingLink(URL(string: "music-remote://pair?id=a&k=b")!) == nil, "nowhere to reach it")
    }

    @Test func portDefaults() throws {
        let link = try #require(PairingLink(URL(string: "music-remote://pair?id=a&k=b&a=10.0.0.2")!))
        #expect(link.port == RemoteControl.defaultPort)
        #expect(link.addresses == ["10.0.0.2"])
    }
}

struct QRCodeTests {
    /// Made by libqrencode 4.1.1: `qrencode -l L -8 -m 0 -t ASCII`, which chose mask 2.
    private let reference = [
            "111111100101011000111011101111111",
            "100000101010001110100110101000001",
            "101110100100001000011111001011101",
            "101110101100110001100011101011101",
            "101110100001001011010101001011101",
            "100000101010100100001010101000001",
            "111111101010101010101010101111111",
            "000000000000000010010111000000000",
            "111110111110110101101010110101010",
            "110100010101001000010101111000101",
            "010011100100000100100110000011010",
            "011101011111101100010110100010110",
            "001101100100110111101010010110001",
            "100000010011001001010001101101001",
            "101010111000110100100010000011110",
            "000110011011100000000100110011111",
            "011101100010110111111010110111000",
            "011000010101001000010110001100111",
            "011101111000010101101110001110010",
            "100100001010101010111100010111110",
            "101101110010110001101011010010010",
            "101001001111001001110001111101111",
            "100000111010001111000010100001110",
            "101111000100100100101110001001110",
            "100100100111010111101010111110011",
            "000000001001101000010000100011001",
            "111111101010101100101011101011110",
            "100000100010101010001111100011100",
            "101110101011010001111000111110011",
            "101110101111101000010101100111000",
            "101110101110011101000010011001010",
            "100000101001000100100100011101100",
            "111111101000010011101011111001010",
    ]

    @Test func matchesAnIndependentEncoderModuleForModule() throws {
        let code = try #require(QRCode(
            "music-remote://pair?id=A1&n=gentoo&p=47823&a=192.168.1.20&k=0123456789abcdef",
            correction: .low
        ))
        #expect(code.version == 4)
        #expect(code.mask == 2, "the penalty rules pick the same mask libqrencode does")
        let rows = code.modules.map { row in row.map { $0 ? "1" : "0" }.joined() }
        #expect(rows == reference)
    }

    @Test func picksTheSmallestVersionThatFits() throws {
        #expect(try #require(QRCode("hi")).version == 1)
        // 14 bytes is the most version 1 holds at medium correction.
        #expect(try #require(QRCode(String(repeating: "a", count: 14))).version == 1)
        #expect(try #require(QRCode(String(repeating: "a", count: 15))).version == 2)
    }

    @Test func tooLongForAnyVersionIsNil() {
        #expect(QRCode(String(repeating: "a", count: 3_000), correction: .high) == nil)
    }
}
