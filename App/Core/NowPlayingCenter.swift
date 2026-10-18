import Foundation
import MediaPlayer
import UIKit

/// Lock screen and Control Centre.
@MainActor
final class NowPlayingCenter {
    var onPlay: (() -> Void)?
    var onPause: (() -> Void)?
    var onToggle: (() -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onSeek: ((Double) -> Void)?

    private var info: [String: Any] = [:]

    init() {
        registerCommands()
    }

    /// Targets are added exactly once. Re-registering per track change is the
    /// standard bug and produces double-skips.
    ///
    /// Every handler is `@Sendable` and hops explicitly. iOS happens to deliver these
    /// on the main thread today, but that is not contractual, and an inherited
    /// `@MainActor` closure called from anywhere else is an immediate trap rather than
    /// a missed button press. The status has to be returned synchronously, so the
    /// action is dispatched and `.success` reported straight away.
    private func registerCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.onPlay?() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.onPause?() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.onToggle?() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.onNext?() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.onPrevious?() }
            return .success
        }

        // Must be enabled or the lock-screen scrubber never appears at all.
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let position = event.positionTime
            Task { @MainActor in self?.onSeek?(position) }
            return .success
        }

        for command in [center.playCommand, center.pauseCommand, center.togglePlayPauseCommand,
                        center.nextTrackCommand, center.previousTrackCommand,
                        center.changePlaybackPositionCommand] {
            command.isEnabled = true
        }

        // Leaving these enabled makes iOS show 15-second skip buttons instead of
        // previous/next, which is wrong for a music app.
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
    }

    /// `elapsedPlaybackTime` is published only on state transitions. The system
    /// extrapolates from (elapsed, rate, timestamp), so pushing it from a timer makes
    /// the lock-screen slider stutter and fight the user's drag.
    func update(
        song: Song,
        elapsed: Double,
        duration: Double,
        isPlaying: Bool,
        speed: Float = 1,
        queueIndex: Int,
        queueCount: Int
    ) {
        // Mutate a local copy and assign once: in-place read-modify-write of
        // nowPlayingInfo is slow and not thread-safe in practice.
        var next = info

        next[MPMediaItemPropertyTitle] = song.title
        next[MPMediaItemPropertyArtist] = song.artist ?? ""
        next[MPMediaItemPropertyAlbumTitle] = song.album ?? ""
        next[MPMediaItemPropertyPlaybackDuration] = duration
        next[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        // The lock screen extrapolates the position from this, so a sped-up track has
        // to say so or its scrubber falls behind.
        next[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? Double(speed) : 0.0
        next[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        next[MPNowPlayingInfoPropertyIsLiveStream] = false
        next[MPNowPlayingInfoPropertyPlaybackQueueIndex] = queueIndex
        next[MPNowPlayingInfoPropertyPlaybackQueueCount] = queueCount
        next[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue

        // Artwork belongs to the previous track until the new one arrives.
        if currentArtworkSongID != song.id {
            next[MPMediaItemPropertyArtwork] = nil
            currentArtworkSongID = nil
        }

        info = next
        MPNowPlayingInfoCenter.default().nowPlayingInfo = next
    }

    private var currentArtworkSongID: String?

    /// Set separately so lock-screen text is never gated on a network fetch.
    ///
    /// The request handler must return synchronously, so the image has to be in hand
    /// before the object is built -- and it is called on MediaPlayer's *own* serial
    /// queue when the system wants a JPEG for the lock screen.
    ///
    /// Hence `@Sendable`, which is load-bearing rather than decorative: without it the
    /// closure inherits this type's `@MainActor` isolation, and Swift 6 inserts an
    /// executor check that trapped (`EXC_BREAKPOINT` in `dispatch_assert_queue`, on a
    /// thread named `*/accessQueue`) the first time anything was played.
    func setArtwork(_ image: UIImage, songID: String? = nil) {
        currentArtworkSongID = songID

        let box = ArtworkBox(image: image)
        let artwork = MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in
            box.image
        }

        info[MPMediaItemPropertyArtwork] = artwork
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// `UIImage` is not formally `Sendable`, but one that is never mutated after
    /// creation is safe to read from any thread -- which is exactly how MediaPlayer
    /// uses it. The box states that assumption in one place instead of spreading
    /// `nonisolated(unsafe)` around.
    private struct ArtworkBox: @unchecked Sendable {
        let image: UIImage
    }

    func clear() {
        info = [:]
        currentArtworkSongID = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
}
