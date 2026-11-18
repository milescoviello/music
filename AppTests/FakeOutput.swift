import Foundation
@testable import Music

/// Stands in for `QueuePlayerOutput`: records what `PlaybackController` asks of the
/// player, and lets a test play the player's part -- a track ending, a tick, a stream
/// that could not be reached -- by calling the callbacks the controller installed.
@MainActor
final class FakeOutput: AudioOutput {
    var elapsed: Double = 0
    var duration: Double = 0
    var isBuffering = false
    var waitingReason: String?
    var holdsCurrent = false
    var unopened: (songID: String, since: Date)?
    var volume: Float = 1
    var rate: Float = 1

    private(set) var loads: [(ids: [String], startAt: Double)] = []
    private(set) var upcoming: [[String]] = []
    private(set) var plays = 0
    private(set) var pauses = 0
    private(set) var stops = 0
    private(set) var seeks: [Double] = []

    func load(window: [Song], startAt: Double) {
        loads.append((window.map(\.id), startAt))
        holdsCurrent = !window.isEmpty
        elapsed = startAt
    }

    func updateUpcoming(_ songs: [Song]) { upcoming.append(songs.map(\.id)) }
    func refreshTransitions() {}
    func sourceChanged(for songID: String) {}
    func play() { plays += 1 }
    func pause() { pauses += 1 }

    func seek(to seconds: Double) {
        seeks.append(seconds)
        elapsed = seconds
    }

    func stop() {
        stops += 1
        holdsCurrent = false
    }

    var onAdvanced: ((String?) -> Void)?
    var onUnreachable: ((String) -> Void)?
    var onFailedMidTrack: ((_ songID: String, _ position: Double) -> Void)?
    var onTick: ((_ elapsed: Double, _ isMoving: Bool) -> Void)?
    var locate: ((Song) -> MediaLocation?)?
    var makeChain: ((Song) -> DSPChain)?
    var transition: ((_ from: Song, _ to: Song) -> Double?)?
    func setSpectrumSink(_ buffer: AudioSampleBuffer?) {}
    var onMediaServicesReset: (() -> Void)?
    var beatMatch: ((Song, Song, Double) -> BeatMatch.Plan?)?
    func replacePlayers() {}
}
