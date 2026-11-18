import AVFoundation
import MediaPlayer
import Observation

/// Plays the songs kept on the watch, with no phone at all: to Bluetooth headphones, as
/// watchOS plays long-form audio (it asks for AirPods if none are connected). The system's
/// Now Playing (`NowPlayingView`, the Digital Crown's volume, the headphones' own buttons)
/// drives it through the remote commands.
@MainActor
@Observable
final class WatchPlayer {
    static let shared = WatchPlayer()

    private(set) var queue: [WatchLink.Track] = []
    private(set) var index = 0
    private(set) var isPlaying = false
    private(set) var hasStarted = false

    var current: WatchLink.Track? { queue.indices.contains(index) ? queue[index] : nil }

    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private var endObserver: NSObjectProtocol?

    private init() {
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.addTarget { _ in
            Task { @MainActor in WatchPlayer.shared.resume() }
            return .success
        }
        commands.pauseCommand.addTarget { _ in
            Task { @MainActor in WatchPlayer.shared.pause() }
            return .success
        }
        commands.togglePlayPauseCommand.addTarget { _ in
            Task { @MainActor in WatchPlayer.shared.toggle() }
            return .success
        }
        commands.nextTrackCommand.addTarget { _ in
            Task { @MainActor in WatchPlayer.shared.skip(by: 1) }
            return .success
        }
        commands.previousTrackCommand.addTarget { _ in
            Task { @MainActor in WatchPlayer.shared.skip(by: -1) }
            return .success
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in WatchPlayer.shared.skip(by: 1) }
        }
    }

    /// Starts `tracks` at `start`, once the system has a route for it.
    func play(_ tracks: [WatchLink.Track], from start: Int = 0, shuffled: Bool = false) async {
        guard !tracks.isEmpty else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, policy: .longFormAudio)
        guard (try? await session.activate(options: [])) == true else { return }
        queue = shuffled ? tracks.shuffled() : tracks
        index = shuffled ? 0 : min(max(start, 0), tracks.count - 1)
        hasStarted = true
        load()
        resume()
    }

    func toggle() {
        isPlaying ? pause() : resume()
    }

    func resume() {
        guard current != nil else { return }
        player.play()
        isPlaying = true
        publish()
    }

    func pause() {
        player.pause()
        isPlaying = false
        publish()
    }

    func skip(by step: Int) {
        // Back from more than three seconds in is back to the start, as everywhere.
        if step < 0, player.currentTime().seconds > 3 {
            player.seek(to: .zero)
            publish()
            return
        }
        let next = index + step
        guard queue.indices.contains(next) else {
            pause()
            return
        }
        index = next
        load()
        if isPlaying { player.play() }
        publish()
    }

    private func load() {
        guard let track = current else { return }
        player.replaceCurrentItem(with: AVPlayerItem(url: WatchModel.file(for: track.id)))
        publish()
    }

    /// What the system's Now Playing shows.
    private func publish() {
        guard let track = current else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyPlaybackDuration: track.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let artist = track.artist { info[MPMediaItemPropertyArtist] = artist }
        if let album = track.album { info[MPMediaItemPropertyAlbumTitle] = album }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
