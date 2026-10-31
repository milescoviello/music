import Foundation
import Testing

@testable import MusicLogic

/// The track-bound modes stop at the boundary themselves, rather than through the fade
/// `onFire` runs -- which, a track having already ended, faded out six seconds of the
/// next song.
@MainActor
struct SleepTimerTests {
    private func song(_ id: String, album: String) -> Song {
        var song = Song(id: id, title: id)
        song.albumId = album
        return song
    }

    @Test func endOfTrackStopsAtTheBoundaryWithoutTheFade() {
        let timer = SleepTimer()
        var faded = false
        timer.onFire = { faded = true }
        timer.armEndOfTrack()

        #expect(timer.trackDidFinish(next: song("b", album: "x")))
        #expect(timer.isArmed == false)
        #expect(faded == false)
        // Once only.
        #expect(timer.trackDidFinish(next: song("c", album: "x")) == false)
    }

    @Test func endOfAlbumWaitsForAnotherAlbum() {
        let timer = SleepTimer()
        timer.armEndOfAlbum(albumID: "x")
        #expect(timer.trackDidFinish(next: song("b", album: "x")) == false)
        #expect(timer.isArmed)
        #expect(timer.trackDidFinish(next: song("c", album: "y")))
        #expect(timer.isArmed == false)
    }

    @Test func endOfAlbumStopsAtTheEndOfTheQueue() {
        let timer = SleepTimer()
        timer.armEndOfAlbum(albumID: "x")
        #expect(timer.trackDidFinish(next: nil))
    }

    @Test func aDeadlineIsNotATrackBoundary() {
        let timer = SleepTimer()
        timer.arm(minutes: 30)
        #expect(timer.trackDidFinish(next: nil) == false)
        #expect(timer.isArmed)
        timer.cancel()
    }
}
