import Foundation
import Testing

@testable import MusicLogic

/// Music asked for from the app: what is sent, and reading back where it stands.
struct GrabTests {
    @Test func aListCountsTheCopiesAndOneRequestListsThem() throws {
        let list = Data("""
        {"id": "a1", "created": 1795620000, "library": "my_music", "kind": "album", "artist": "Glass Harbor",
         "title": "Salt Year", "choose": true, "state": "choosing", "progress": null,
         "targets": [{"key": "a000", "kind": "album", "artist": "Glass Harbor", "title": "Salt Year",
                      "status": "FOUND", "choice": 0, "copies": 3, "state": "choosing", "detail": "3 lossless copies"}]}
        """.utf8)
        let summary = try JSONDecoder().decode(SonicClient.GrabRequest.self, from: list)
        #expect(summary.library == .myMusic)
        #expect(summary.targets[0].copyCount == 3)
        #expect(summary.targets[0].copies.isEmpty)
        #expect(summary.detail == "3 lossless copies")

        let one = Data("""
        {"id": "a1", "library": "music", "choose": false, "state": "downloading",
         "progress": {"done": 50, "total": 200},
         "targets": [{"key": "s000", "kind": "song", "artist": "Glass Harbor", "title": "Low Tide",
                      "state": "downloading", "detail": "1 of 2 files", "progress": {"done": 50, "total": 200},
                      "copies": [{"index": 0, "peer": "someone", "folder": "Low Tide", "tracks": 1,
                                  "bytes": 200, "free": true, "queue": 0, "speed": 1000000.0,
                                  "formats": ["flac"], "files": [{"name": "01 Low Tide.flac", "bytes": 200, "seconds": 241}]}]}]}
        """.utf8)
        let detail = try JSONDecoder().decode(SonicClient.GrabRequest.self, from: one)
        #expect(detail.targets[0].copies.first?.formats == ["flac"])
        #expect(detail.progress?.fraction == 0.25)
        #expect(detail.state.isActive)
    }

    @Test func aStateFromANewerServerReadsAsFailedRatherThanBreakingTheList() throws {
        let data = Data(#"{"id": "b", "library": "music", "choose": false, "state": "pondering", "targets": []}"#.utf8)
        #expect(try JSONDecoder().decode(SonicClient.GrabRequest.self, from: data).state == .failed)
    }

    @Test func whatIsSentUsesTheServersNames() throws {
        let ask = AddMusicItem.song(artist: "Glass Harbor", title: "Low Tide", albumID: "MPREb_1", videoID: "abcdefghijk")
            .ask(library: .myMusic, choose: true, albumToo: true)
        let sent = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ask)) as? [String: Any]
        #expect(sent?["library"] as? String == "my_music")
        #expect(sent?["album_too"] as? Bool == true)
        #expect(sent?["video_id"] as? String == "abcdefghijk")
        #expect(sent?["choose"] as? Bool == true)
    }

    @Test func aSongOnItsOwnIsOfferedItsAlbum() {
        var song = Song(id: "s2", title: "Low Tide")
        song.album = "Low Tide"
        #expect(song.isOnItsOwn)
        song.album = "Low Tide (Radio Edit) - Single"
        #expect(song.isOnItsOwn)
        song.album = "Salt Year"
        #expect(!song.isOnItsOwn)
        song.album = "Low Tide"
        let ask = AddMusicItem.fullAlbum(song).ask(library: .music, choose: false, albumToo: false)
        #expect(ask.kind == .song && ask.albumToo)
    }

    @Test func aLosslessRequestNamesTheSongToReplace() {
        var song = Song(id: "s1", title: "Low Tide")
        song.artist = "Glass Harbor"
        song.suffix = "mp3"
        song.duration = 241
        #expect(song.isLossy)
        let ask = AddMusicItem.lossless(song).ask(library: .music, choose: false, albumToo: false)
        #expect(ask.replace == "s1")
        #expect(ask.length == 241)
        song.suffix = "flac"
        #expect(!song.isLossy)
    }
}
