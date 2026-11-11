import AVFoundation
import UIKit

/// Plays a music video: AVPlayer on the sonic service's own HLS (`VideoClient.masterURL`),
/// adaptive up to 1080p, with no ads because none of YouTube's player is involved.
///
/// Reports what the player's controls need four times a second: the time, the length, and
/// playing in the sense the rest of the app means it -- asked to play, even while waiting for
/// the network -- with the waiting reported apart.
///
/// The video keeps playing with the screen locked or the app in the background, as its
/// sound. iOS pauses a player whose picture is on screen when the app leaves it, so the
/// surfaces let go of the player then and take it back on return (`attach`).
///
/// The desktop's counterpart, with the same shape, is `Linux/.../Platform/VideoEngine.swift`.
@MainActor
final class VideoEngine {
    struct Progress: Equatable, Sendable {
        var elapsed: Double
        var duration: Double
        var isPlaying: Bool
        var isWaiting: Bool
    }

    var onProgress: ((Progress) -> Void)?
    var onEnd: (() -> Void)?
    var onFailure: ((String) -> Void)?

    /// What the video surfaces show.
    let player = AVPlayer()

    private var wantsPlaying = false
    private var pendingSeek: Double?
    private var itemObservations: [NSKeyValueObservation] = []
    private var itemNotifications: [NSObjectProtocol] = []
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var surfaces: [WeakLayer] = []
    private var isInBackground = false

    private struct WeakLayer {
        weak var layer: AVPlayerLayer?
    }

    init() {
        player.automaticallyWaitsToMinimizeStalling = true
        player.allowsExternalPlayback = true
        player.preventsDisplaySleepDuringVideoPlayback = true
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 4), queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.report() }
        }
        // `@Sendable`, so it is never taken for main-actor code: KVO may call it from any
        // thread.
        statusObservation = player.observe(\.timeControlStatus) { @Sendable [weak self] _, _ in
            Task { @MainActor in self?.report() }
        }
        let center = NotificationCenter.default
        _ = center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.enteredBackground(true) }
        }
        _ = center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.enteredBackground(false) }
        }
    }

    var isOpen: Bool { player.currentItem != nil }
    /// The Streaming settings' video quality: every height, or the one.
    var quality: VideoQuality = .auto

    /// Opens the video `seconds` in, playing or not.
    func open(videoID: String, client: VideoClient, at seconds: Double, playing: Bool) {
        stop()
        guard let url = client.masterURL(videoID: videoID, quality: quality) else {
            onFailure?("The video service's address is not valid.")
            return
        }
        // Every height up to 1080p is in the playlist, and AVPlayer picks among them by
        // the connection: the best it can keep up with, wherever the phone is. Unless a
        // quality is chosen: then the playlist has that one height.
        let item = AVPlayerItem(url: url)
        let itemID = ObjectIdentifier(item)
        itemObservations.append(item.observe(\.status) { @Sendable [weak self] item, _ in
            let status = item.status
            let message = item.error.map(Diagnostics.describe)
            Task { @MainActor in self?.statusChanged(itemID, status, message) }
        })
        let center = NotificationCenter.default
        itemNotifications.append(center.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.ended() }
        })
        itemNotifications.append(center.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] note in
            let message = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)
                .map(Diagnostics.describe) ?? "The video stopped."
            MainActor.assumeIsolated { self?.fail(message) }
        })
        pendingSeek = seconds > 0.5 ? seconds : nil
        wantsPlaying = playing
        player.replaceCurrentItem(with: item)
        if playing { player.play() }
        report()
    }

    func play() {
        wantsPlaying = true
        guard isOpen else { report(); return }
        player.play()
        report()
    }

    func pause() {
        wantsPlaying = false
        player.pause()
        report()
    }

    func seek(to seconds: Double) {
        guard let item = player.currentItem, item.status == .readyToPlay else {
            pendingSeek = seconds
            report()
            return
        }
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        let tolerance = CMTime(value: 1, timescale: 4)
        player.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance)
        report()
    }

    func stop() {
        player.pause()
        for observation in itemObservations { observation.invalidate() }
        itemObservations.removeAll()
        for token in itemNotifications { NotificationCenter.default.removeObserver(token) }
        itemNotifications.removeAll()
        player.replaceCurrentItem(with: nil)
        wantsPlaying = false
        pendingSeek = nil
    }

    // MARK: - Surfaces

    /// A layer showing the video. Held weakly; it lets go while the app is in the
    /// background, so iOS goes on playing the sound.
    func attach(_ layer: AVPlayerLayer) {
        surfaces.removeAll { $0.layer == nil || $0.layer === layer }
        surfaces.append(WeakLayer(layer: layer))
        layer.player = isInBackground ? nil : player
    }

    func detach(_ layer: AVPlayerLayer) {
        surfaces.removeAll { $0.layer == nil || $0.layer === layer }
        if layer.player === player { layer.player = nil }
    }

    private func enteredBackground(_ background: Bool) {
        isInBackground = background
        for surface in surfaces {
            surface.layer?.player = background ? nil : player
        }
        // Letting go of the picture can pause it on the way out; the sound is wanted.
        if background, wantsPlaying, isOpen {
            player.play()
        }
    }

    // MARK: - State

    private func statusChanged(_ id: ObjectIdentifier, _ status: AVPlayerItem.Status, _ message: String?) {
        guard let item = player.currentItem, ObjectIdentifier(item) == id else { return }
        switch status {
        case .readyToPlay:
            if let pending = pendingSeek {
                pendingSeek = nil
                seek(to: pending)
            }
            if wantsPlaying { player.play() }
        case .failed:
            fail(message ?? "The video could not be opened.")
        default:
            break
        }
        report()
    }

    private func ended() {
        wantsPlaying = false
        report()
        onEnd?()
    }

    private func fail(_ message: String) {
        stop()
        onFailure?(message)
    }

    private func report() {
        guard let item = player.currentItem else { return }
        let now = pendingSeek ?? player.currentTime().seconds
        let length = item.duration.seconds
        let waiting = item.status != .readyToPlay
            || (wantsPlaying && player.timeControlStatus == .waitingToPlayAtSpecifiedRate)
        onProgress?(Progress(
            elapsed: now.isFinite ? max(0, now) : 0,
            duration: length.isFinite ? length : 0,
            isPlaying: wantsPlaying,
            isWaiting: waiting
        ))
    }
}
