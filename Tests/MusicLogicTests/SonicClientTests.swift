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
}
