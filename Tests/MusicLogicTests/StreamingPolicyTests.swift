import Foundation
import Testing
@testable import MusicLogic

struct StreamingPolicyTests {
    private func song(suffix: String = "flac", bitRate: Int? = 900) -> Song {
        var song = Song(id: "s", title: "S")
        song.suffix = suffix
        song.bitRate = bitRate
        return song
    }

    @Test func maximumAsksForTheStoredFile() {
        let policy = StreamingPolicy()
        #expect(policy.variant(for: song(), on: .wifi) == .original)
        #expect(policy.variant(for: song(), on: .cellular) == .original)
    }

    @Test func aCeilingConvertsOnlyWhatIsAboveIt() {
        var policy = StreamingPolicy()
        policy.cellularQuality = .kbps128
        #expect(policy.variant(for: song(), on: .cellular) == .mp3(kbps: 128))
        // Converting a 128 kbps MP3 to 128 kbps would only add a generation of loss.
        #expect(policy.variant(for: song(suffix: "mp3", bitRate: 128), on: .cellular) == .original)
        #expect(policy.variant(for: song(suffix: "mp3", bitRate: 320), on: .cellular) == .mp3(kbps: 128))
        // Wi-Fi is its own setting.
        #expect(policy.variant(for: song(), on: .wifi) == .original)
    }

    @Test func undecodableContainersAreAlwaysConverted() {
        var policy = StreamingPolicy()
        #expect(policy.variant(for: song(suffix: "opus", bitRate: 160), on: .wifi) == .mp3(kbps: 320))
        policy.wifiQuality = .kbps192
        #expect(policy.variant(for: song(suffix: "ogg"), on: .wifi) == .mp3(kbps: 192))
    }

    @Test func downloadsWinAccordingToTheSettingButAlwaysOffline() {
        var policy = StreamingPolicy()
        #expect(policy.usesDownload(on: .wifi))

        policy.preferDownloads = .onCellular
        #expect(!policy.usesDownload(on: .wifi))
        #expect(policy.usesDownload(on: .cellular))

        policy.preferDownloads = .never
        #expect(!policy.usesDownload(on: .cellular))
        #expect(policy.usesDownload(on: .offline))
    }

    @Test func onlyNextTrackStillCachesTheNextTrack() {
        var policy = StreamingPolicy()
        policy.wifiCacheAhead = 0
        #expect(policy.tracksAhead(on: .wifi) == 1)
        #expect(policy.tracksAhead(on: .cellular) == 5)
        #expect(policy.tracksAhead(on: .offline) == 0)
    }

    @Test func theOriginalIsFetchedRawSoItCanBeSeeked() {
        let query = StreamingPolicy.streamQuery(for: song(), variant: .original)
        #expect(query["format"] == "raw")
        let converted = StreamingPolicy.streamQuery(for: song(), variant: .mp3(kbps: 96))
        #expect(converted["format"] == "mp3")
        #expect(converted["maxBitRate"] == "96")
    }

    @Test func aPolicyFromAnOlderBuildStillDecodes() throws {
        let stored = try JSONEncoder().encode(StreamingPolicy())
        let decoded = try JSONDecoder().decode(StreamingPolicy.self, from: stored)
        #expect(decoded == StreamingPolicy())

        // Only some of the fields, as a build with fewer settings would have written.
        let partial = try JSONDecoder().decode(StreamingPolicy.self, from: Data(#"{"cellularQuality":128}"#.utf8))
        #expect(partial.cellularQuality == .kbps128)
        #expect(partial.wifiCacheAhead == 15)
    }
}

struct TrackShapeTests {
    private let sampleRate = 48_000.0

    /// A 1 kHz tone at `amplitude`, shaped by `envelope` over its length.
    private func tone(seconds: Double, amplitude: Float = 0.5, envelope: (Double) -> Double = { _ in 1 }) -> [Float] {
        let count = Int(seconds * sampleRate)
        return (0..<count).map { index in
            let t = Double(index) / sampleRate
            let fraction = t / seconds
            return amplitude * Float(envelope(fraction)) * Float(sin(2 * .pi * 1_000 * t))
        }
    }

    /// The tones below measure about −9 LUFS momentary. A steady tone never rises
    /// above its own integrated loudness, so a threshold of "loudness + 2 dB" would
    /// never be crossed; music does. A track gain of −6 dB (loudness −12, threshold
    /// −10) stands in for that, the way a real track's ReplayGain does.
    private func song(_ id: String, album: String? = nil, track: Int? = nil) -> Song {
        var song = Song(id: id, title: id)
        song.albumId = album
        song.track = track
        song.replayGain = ReplayGain(trackGain: -6)
        return song
    }

    @Test func aLongFadeOutMeasuresAsALongOutro() {
        // Fifteen seconds that fade linearly to silence, after a steady intro.
        let steady = tone(seconds: 15)
        let fading = tone(seconds: 15) { 1 - $0 }
        let shape = TrackShape.measure(intro: [steady], outro: [fading], sampleRate: sampleRate)
        let threshold = SweetFades.threshold(loudness: -12)

        let outro = shape.outro.time(toReach: threshold)
        let intro = shape.intro.time(toReach: threshold)
        #expect(outro > 2)
        #expect(intro < 0.5)
    }

    @Test func twoAbruptTracksMeetGapless() {
        let steady = tone(seconds: 15)
        let shape = TrackShape.measure(intro: [steady], outro: [steady], sampleRate: sampleRate)
        let overlap = TransitionPlanner.overlap(
            from: song("a"), to: song("b"), sweetFades: true, outgoing: shape, incoming: shape
        )
        #expect(overlap == nil)
    }

    @Test func aFadeIntoAFadeOverlaps() {
        let fadeOut = TrackShape.measure(
            intro: [tone(seconds: 15)], outro: [tone(seconds: 15) { 1 - $0 }], sampleRate: sampleRate
        )
        let fadeIn = TrackShape.measure(
            intro: [tone(seconds: 15) { $0 }], outro: [tone(seconds: 15)], sampleRate: sampleRate
        )
        let overlap = TransitionPlanner.overlap(
            from: song("a"), to: song("b"), sweetFades: true, outgoing: fadeOut, incoming: fadeIn
        )
        #expect((overlap ?? 0) > 3)
        #expect((overlap ?? 0) <= SweetFades.maximumOverlap)
    }

    @Test func anUnmeasuredSideGetsTheFallback() {
        #expect(TransitionPlanner.overlap(
            from: song("a"), to: song("b"), sweetFades: true, outgoing: nil, incoming: nil
        ) == SweetFades.fallbackOverlap)
    }

    @Test func albumOrderAndTheSettingStillWin() {
        let a = song("a", album: "x", track: 1)
        let b = song("b", album: "x", track: 2)
        #expect(TransitionPlanner.overlap(from: a, to: b, sweetFades: true, outgoing: nil, incoming: nil) == nil)
        #expect(TransitionPlanner.overlap(from: song("a"), to: song("b"), sweetFades: false, outgoing: nil, incoming: nil) == nil)
    }

    @Test func aStoredShapeRoundTrips() throws {
        let shape = TrackShape.measure(intro: [tone(seconds: 2)], outro: [tone(seconds: 2)], sampleRate: sampleRate)
        let decoded = try JSONDecoder().decode(TrackShape.self, from: JSONEncoder().encode(shape))
        #expect(decoded == shape)
    }

    @Test func theEnvelopeIsRelativeToTheLoudestSliceAndFloored() throws {
        let envelope = try #require(TrackShape.envelope(fromPower: [1, 0.1, 0, 1e-9]))
        #expect(envelope[0] == 1)
        // 10 dB down on a 36 dB scale.
        #expect(abs(envelope[1] - 26.0 / 36.0) < 0.001)
        #expect(envelope[2] == 0)
        // 90 dB down is below the floor.
        #expect(envelope[3] == 0)
        #expect(TrackShape.envelope(fromPower: []) == nil)
        #expect(TrackShape.envelope(fromPower: [0, 0]) == nil)
    }

    @Test func aShapeWithoutAnEnvelopeStillDecodes() throws {
        let old = #"{"intro":{"levels":[-20],"hop":0.1},"outro":{"levels":[-20],"hop":0.1}}"#
        let shape = try JSONDecoder().decode(TrackShape.self, from: Data(old.utf8))
        #expect(shape.envelope == nil)
    }
}
