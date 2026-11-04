import Foundation

/// The phone's audio-session rules, as far as a desktop has them.
///
/// There are no interruptions to latch — a call does not take the speaker away from a
/// desktop app — but one rule carries over intact: when the device playing goes away
/// (headphones unplugged, a Bluetooth headset switched off), pause rather than carry on
/// through the laptop's speakers. The sound server moves the stream to another device by
/// itself; `PulseOutput` notices that the device it was on no longer exists and reports
/// it here.
@MainActor
final class AudioSessionCoordinator {
    var onPause: (() -> Void)?
    var onResume: (() -> Void)?
    /// Never raised: the sound server has no reset that kills the app's streams unseen.
    var onMediaServicesReset: (() -> Void)?

    private var isPlaying = false

    func configure() {
        AudioDevice.onLost = { [weak self] in
            guard let self, isPlaying else { return }
            onPause?()
        }
    }

    func activate() {}

    func deactivate() {}

    func resumeIfInterruptionWentUnreported() {}

    func setUpAgain() {}

    func noteIsPlaying(_ isPlaying: Bool) {
        self.isPlaying = isPlaying
    }
}

/// The sound server's word that the device the music was on has gone.
@MainActor
enum AudioDevice {
    static var onLost: (() -> Void)?
}
