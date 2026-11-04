import Foundation

/// The phone's audio-session rules, as far as a desktop has them.
///
/// When the device playing goes away (headphones unplugged, a Bluetooth headset switched
/// off), pause rather than carry on through the laptop's speakers. The sound server moves
/// the stream to another device by itself; `PulseOutput` notices that the device it was
/// on no longer exists and reports it here.
///
/// The interruption the phone has for a call is the sound server's cork request: pause,
/// and play again when it is lifted, if it was the request that paused it.
@MainActor
final class AudioSessionCoordinator {
    var onPause: (() -> Void)?
    var onResume: (() -> Void)?
    /// Never raised: the sound server has no reset that kills the app's streams unseen.
    var onMediaServicesReset: (() -> Void)?

    private var isPlaying = false
    private var pausedForCork = false

    func configure() {
        AudioDevice.onLost = { [weak self] in
            guard let self, isPlaying else { return }
            pausedForCork = false
            onPause?()
        }
        AudioDevice.onCork = { [weak self] corked in
            guard let self else { return }
            if corked, isPlaying {
                pausedForCork = true
                Task { await Diagnostics.shared.record("audio", "the sound server asked music to pause") }
                onPause?()
            } else if !corked, pausedForCork {
                pausedForCork = false
                Task { await Diagnostics.shared.record("audio", "the sound server let music carry on") }
                onResume?()
            }
        }
    }

    func activate() {}

    func deactivate() {}

    func resumeIfInterruptionWentUnreported() {}

    func setUpAgain() {}

    func noteIsPlaying(_ isPlaying: Bool) {
        self.isPlaying = isPlaying
        // Played by hand meanwhile: the lifted request must not start it again later.
        if isPlaying { pausedForCork = false }
    }
}

/// The sound server's word about the music's stream: the device it was on has gone, or
/// it is asked to pause (true) or may carry on (false).
@MainActor
enum AudioDevice {
    static var onLost: (() -> Void)?
    static var onCork: ((Bool) -> Void)?
}
