import Foundation
import Testing

@testable import MusicLogic

/// The Soulseek monitor: reading the server's answer, and what the screens say about it.
struct SlskdMonitorTests {
    private static let answer = Data("""
    {"checked": 1795620000,
     "slskd": {"reachable": true, "state": "Connected, LoggedIn", "connected": true, "loggedIn": true,
               "server": "server.example", "username": "someone", "version": "1.2.3", "updateAvailable": false,
               "shares": {"files": 68633, "folders": 2838, "scanning": false, "ready": true},
               "uploads": {"sending": 1, "waiting": 4, "speed": 2048}},
     "running": 1,
     "downloads": {"downloading": 1, "queued": 1, "speed": 1048576, "folders": [
        {"id": "a\\u001fx", "user": "sharer", "folder": "Salt Year", "state": "downloading", "files": 4,
         "filesDone": 1, "filesFailed": 0, "bytes": 400, "bytesDone": 100, "speed": 1048576, "at": 1795619900,
         "why": null, "job": "app-20261125aa", "source": "Music app",
         "items": [{"name": "01 Low Tide.flac", "state": "InProgress", "bytes": 100, "bytesDone": 50, "why": null}]},
        {"id": "b\\u001fy", "user": "other", "folder": "Glass", "state": "queued", "files": 2, "filesDone": 0,
         "filesFailed": 0, "bytes": 2048, "bytesDone": 0, "speed": 0, "at": null, "why": null, "job": null,
         "source": null, "items": []},
        {"id": "c\\u001fz", "user": "third", "folder": "Old", "state": "rewinding", "files": 1, "filesDone": 0,
         "filesFailed": 1, "bytes": 1, "bytesDone": 0, "speed": 0, "at": null, "why": "File not shared.",
         "job": null, "source": null,
         "items": [{"name": "x.flac", "state": "Completed, Rejected", "bytes": 1, "bytesDone": 0, "why": "File not shared."}]}]},
     "imports": [{"id": "app-20261125aa/a000", "job": "app-20261125aa", "source": "Music app", "kind": "album",
                  "artist": "Glass Harbor", "title": "Salt Year", "library": "my_music", "state": "indexing",
                  "detail": "Copied in: waiting for Navidrome to list it", "at": 1795619000, "files": 4,
                  "flagged": 1, "folder": "Glass Harbor/Salt Year (2024)"}]}
    """.utf8)

    @Test func readsTheServersAnswer() throws {
        let monitor = try JSONDecoder().decode(SonicClient.SlskdMonitor.self, from: Self.answer)
        #expect(monitor.slskd.isOnline)
        #expect(monitor.slskd.headline == "Connected as someone")
        #expect(monitor.slskd.connectionLine == "Signed in at server.example")
        #expect(monitor.slskd.sharingLine == "68,633 files in 2,838 folders")
        #expect(monitor.downloads.folders[0].fraction == 0.25)
        // A state from a newer server reads as failed rather than breaking the page.
        #expect(monitor.downloads.folders[2].state == .failed)
        #expect(monitor.imports[0].state.isUnderWay)
    }

    @Test func theSummarySaysWhatIsMoving() throws {
        let monitor = try JSONDecoder().decode(SonicClient.SlskdMonitor.self, from: Self.answer)
        #expect(monitor.activityLine == "1 downloading · 1 waiting · 1 importing · 1 MB/s")
    }

    @Test func eachFolderAndImportSaysWhereItStands() throws {
        let monitor = try JSONDecoder().decode(SonicClient.SlskdMonitor.self, from: Self.answer)
        let now = Date(timeIntervalSince1970: 1_795_620_000)
        let folders = monitor.downloads.folders
        #expect(folders[0].detailLine(now: now) == "1 of 4 files · 100 bytes of 400 bytes · 1 MB/s")
        #expect(folders[0].sourceLine == "sharer · Music app")
        #expect(folders[1].detailLine(now: now) == "Waiting in other's queue · 2 files, 2 KB")
        #expect(folders[2].detailLine(now: now) == "Failed: File not shared.")
        #expect(folders[2].items[0].stateLine == "Rejected: File not shared.")
        #expect(folders[0].items[0].stateLine == "50% of 100 bytes")
        let item = monitor.imports[0]
        #expect(item.subtitle == "Glass Harbor · Album · My Music · Music app")
        #expect(item.detailLine(now: now) == "Copied in: waiting for Navidrome to list it · 1 flagged by the fake-FLAC check · 16 min ago")
    }

    @Test func slskdAwayOrSignedOutSaysSo() {
        let away = SonicClient.SlskdStatus(reachable: false, state: nil, connected: nil, loggedIn: nil, server: nil,
                                           username: nil, version: nil, updateAvailable: nil, shares: nil,
                                           uploads: nil, error: "timed out")
        #expect(away.headline == "slskd isn't answering")
        #expect(away.connectionLine == "timed out")
        #expect(!away.isOnline)
        let out = SonicClient.SlskdStatus(reachable: true, state: "Disconnected", connected: false, loggedIn: false,
                                          server: "server.example", username: "someone", version: nil,
                                          updateAvailable: nil, shares: nil, uploads: nil, error: nil)
        #expect(out.headline == "Not connected to Soulseek")
        #expect(out.connectionLine == "Disconnected · server.example")
    }

    @Test func countsAndTimesReadNaturally() {
        #expect(SlskdText.count(1, "file") == "1 file")
        #expect(SlskdText.count(999, "file") == "999 files")
        #expect(SlskdText.count(1_234_567, "file") == "1,234,567 files")
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(SlskdText.ago(now.addingTimeInterval(-20), now: now) == "just now")
        #expect(SlskdText.ago(now.addingTimeInterval(-3 * 3_600), now: now) == "3 hr ago")
        #expect(SlskdText.ago(now.addingTimeInterval(-86_400 - 5), now: now) == "yesterday")
        #expect(SlskdText.ago(nil, now: now) == nil)
    }
}
