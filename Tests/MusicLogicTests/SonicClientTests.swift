import Foundation
import Testing
@testable import MusicLogic

struct SonicClientTests {
    private let client = SonicClient(configuration: .default)

    @Test func pathsAndQueriesAreTheServicesContract() {
        #expect(client.url("v1/tracks/abc/levels", ["points": "128"])?.absoluteString
            == "http://192.168.1.148:8650/v1/tracks/abc/levels?points=128")
        // Sorted, so the same request is always the same URL.
        #expect(client.url("v1/path", ["to": "b", "from": "a", "steps": "10"])?.absoluteString
            == "http://192.168.1.148:8650/v1/path?from=a&steps=10&to=b")
    }

    @Test func responsesDecode() throws {
        let levels = try JSONDecoder().decode(SonicClient.Levels.self, from: Data(#"{"id":"s","hop":0.1,"levels":[-39.9,-12.5]}"#.utf8))
        #expect(levels.levels == [-39.9, -12.5])
        let status = try JSONDecoder().decode(SonicClient.Status.self, from: Data(#"{"tracks":10,"analysed":4,"analysing":true,"model":"musicnn","version":1}"#.utf8))
        #expect(status.analysed == 4)

        // The service's real answer, extra keys and all.
        let rhythm = try JSONDecoder().decode(SonicClient.Rhythm.self, from: Data(#"""
        {"id":"s","bpm":88.77,"confidence":1.434,"beats":[0.65,1.3,1.95],"key":"A","scale":"major","keyStrength":0.81,"duration":193.5,"loudness":-16.65}
        """#.utf8))
        #expect(rhythm.beats.count == 3)
        #expect(rhythm.key == "A")
        let none = try JSONDecoder().decode(SonicClient.Rhythm.self, from: Data(#"{"id":"s","bpm":null,"confidence":null,"beats":[],"key":null,"scale":null,"keyStrength":null,"duration":10,"loudness":null}"#.utf8))
        #expect(none.bpm == nil)
    }

    @Test func theSeekbarShapeIsPlexampsTransform() {
        let heights = SeekbarShape.heights(fromLevels: [-60, -35, -20, -10, -10])
        // Anything at or under the floor is flat zero; the loudest reaches the full height.
        #expect(heights[0] == 0)
        #expect(heights[1] == 0)
        #expect(abs(heights[3] - SeekbarShape.maximumHeight) < 0.001)
        #expect(heights[2] > 0 && heights[2] < heights[3])
        #expect(SeekbarShape.heights(fromLevels: [-50, -50]) == [0, 0])
    }

    @Test func interpolationKeepsTheEndsAndFillsBetween() {
        let out = SeekbarShape.interpolate([0, 10], to: 5)
        #expect(out == [0, 2.5, 5, 7.5, 10])
        #expect(SeekbarShape.interpolate([3], to: 3) == [3, 3, 3])
        #expect(SeekbarShape.interpolate([], to: 3).isEmpty)
    }

    @Test func aShapeFromTheServicesReadingsReadsBothEnds() throws {
        // 30 s at 100 ms: a 5 s fade in, steady, a 10 s fade out.
        var levels = [Float](repeating: -10, count: 300)
        for index in 0..<50 { levels[index] = -40 + Float(index) * 0.6 }
        for index in 0..<100 { levels[299 - index] = -40 + Float(index) * 0.3 }
        let shape = try #require(TrackShape.fromLevels(levels, hop: 0.1))
        #expect(shape.intro.levels.count == 150)
        #expect(shape.intro.levels.first == -40)
        // The outro reads from the end backwards.
        #expect(shape.outro.levels.first == -40)
        #expect(shape.outro.levels.last == -10)
        let threshold = SweetFades.threshold(loudness: -12)
        #expect(shape.outro.time(toReach: threshold) > shape.intro.time(toReach: threshold))
        #expect(TrackShape.fromLevels([-20], hop: 0.1) == nil)
    }

    @Test func tagsWithSpacesStillMakeAPath() {
        let url = client.url("v1/tags/female vocalists/tracks", ["limit": "5"])
        #expect(url?.absoluteString == "http://192.168.1.148:8650/v1/tags/female%20vocalists/tracks?limit=5")
    }
}
