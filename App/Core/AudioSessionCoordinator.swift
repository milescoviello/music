import AVFoundation
import CallKit
import Foundation

/// Owns the `AVAudioSession` and the notifications that go with it.
///
/// The rules encoded here are the ones that produce "playback resumes but is
/// silent" and "the app stole audio at launch" bugs when they are missed.
@MainActor
final class AudioSessionCoordinator {
    /// Called when the system wants playback paused or resumed.
    var onPause: (() -> Void)?
    var onResume: (() -> Void)?

    private var isActivated = false
    /// Mirrors the controller's play state, kept current by `noteIsPlaying`.
    private var isPlaying = false
    /// Latched when an interruption arrives while playing, and the only thing that
    /// authorises an automatic resume.
    private var wasInterruptedWhilePlaying = false
    /// When the interruption began, for how long it lasted.
    private var interruptedAt: Date?
    /// Asked at an interruption whether a call is under way: the session itself says
    /// only that something else took the audio.
    private let calls = CXCallObserver()
    private var observers: [NSObjectProtocol] = []

    func configure() {
        let session = AVAudioSession.sharedInstance()
        // .longFormAudio is what marks this as a music app for routing and AirPlay 2.
        // Deliberately no .mixWithOthers: it is incompatible with that policy.
        try? session.setCategory(.playback, mode: .default, policy: .longFormAudio)
        observeNotifications()
    }

    /// Activated lazily on the first play. Activating a `.playback` session at
    /// launch silently stops whatever the user was already listening to.
    func activate() {
        guard !isActivated else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        isActivated = true
    }

    /// Holding an active session with nothing playing invites termination.
    func deactivate() {
        guard isActivated else { return }
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
        isActivated = false
    }

    private func observeNotifications() {
        let center = NotificationCenter.default

        // The raw values are pulled out *before* hopping to the main actor:
        // `Notification` is not `Sendable`, so it cannot cross the boundary, and the
        // two `UInt`s are all these handlers ever needed.
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let info = notification.userInfo
            let rawType = info?[AVAudioSessionInterruptionTypeKey] as? UInt
            let rawOptions = info?[AVAudioSessionInterruptionOptionKey] as? UInt
            let rawReason = info?[AVAudioSessionInterruptionReasonKey] as? UInt

            MainActor.assumeIsolated {
                self?.handleInterruption(rawType: rawType, rawOptions: rawOptions, rawReason: rawReason)
            }
        })

        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt

            MainActor.assumeIsolated {
                self?.handleRouteChange(rawReason: rawReason)
            }
        })
    }

    private func handleInterruption(rawType: UInt?, rawOptions: UInt?, rawReason: UInt?) {
        guard let rawType,
              let type = AVAudioSession.InterruptionType(rawValue: rawType)
        else { return }

        switch type {
        case .began:
            // Latched **here**, before pausing. `onPause` runs the controller's own
            // `pause()`, which reports `noteIsPlaying(false)` -- so reading the play state
            // at `.ended` instead always saw false and auto-resume could never fire. That
            // is the whole reason an Instagram reel used to stop the music for good.
            //
            // No special case for `.appWasSuspended`: it was never followed by `.ended`
            // and iOS 16 stopped sending it at all.
            wasInterruptedWhilePlaying = isPlaying
            interruptedAt = .now
            log("interrupted\(isPlaying ? " while playing" : ""), by \(cause(rawReason))")
            onPause?()

        case .ended:
            let options = rawOptions
                .map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []

            let resumes = options.contains(.shouldResume) && wasInterruptedWhilePlaying
            let lasted = interruptedAt.map { " after \(Diagnostics.duration(Date.now.timeIntervalSince($0)))" } ?? ""
            interruptedAt = nil
            log("interruption over\(lasted): \(resumes ? "resuming" : options.contains(.shouldResume) ? "wasn't playing" : "iOS says don't resume")")
            guard resumes else { return }
            resumeAfterInterruption()

        @unknown default:
            break
        }
    }

    /// What took the audio, as near as iOS will say. A call is asked of CallKit; the
    /// session's own reason covers a muted mic or a lost device; anything else is either
    /// another app's sound, if one is playing, or Siri, an alarm or a system sound.
    private func cause(_ rawReason: UInt?) -> String {
        if calls.calls.contains(where: { !$0.hasEnded }) { return "a call" }
        if let rawReason, let reason = AVAudioSession.InterruptionReason(rawValue: rawReason) {
            switch reason {
            case .builtInMicMuted: return "the built-in mic being muted"
            case .routeDisconnected: return "the audio device disconnecting"
            default: break
            }
        }
        return AVAudioSession.sharedInstance().isOtherAudioPlaying
            ? "another app's audio" : "Siri, an alarm or a system sound"
    }

    private func handleRouteChange(rawReason: UInt?) {
        guard let rawReason,
              let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason)
        else { return }

        // Which way the sound now goes, by kind, never by name: "AirPods" is a port
        // type, but a device's name can be a person's.
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType.rawValue)
        log("route changed (\(Self.describe(reason))), now \(outputs.joined(separator: ", "))")

        // Headphones pulled out or an AirPod removed. Never auto-resume when a new
        // device appears -- that starts music in someone's pocket.
        if reason == .oldDeviceUnavailable {
            onPause?()
        }
    }

    /// Calls, other apps, headphones: the commonest reasons music stops by itself, and
    /// so the first thing to look for in the log when it did.
    private func log(_ what: String) {
        Task { await Diagnostics.shared.record("audio", what) }
    }

    private static func describe(_ reason: AVAudioSession.RouteChangeReason) -> String {
        switch reason {
        case .newDeviceAvailable: "a device came"
        case .oldDeviceUnavailable: "a device went"
        case .categoryChange: "category change"
        case .override: "override"
        case .wakeFromSleep: "wake from sleep"
        case .noSuitableRouteForCategory: "no suitable route"
        case .routeConfigurationChange: "configuration change"
        default: "reason \(reason.rawValue)"
        }
    }

    /// Resumes when the interruption ended without the system saying so.
    ///
    /// `.ended` is not guaranteed: an app that never deactivates its own session leaves
    /// ours interrupted indefinitely, and coming back to the app is then the only signal
    /// there is. Gated on the same latch, and on nothing else currently holding the
    /// speaker, so this can never start music the user did not ask for.
    func resumeIfInterruptionWentUnreported() {
        guard wasInterruptedWhilePlaying,
              !AVAudioSession.sharedInstance().isOtherAudioPlaying
        else { return }
        resumeAfterInterruption()
    }

    private func resumeAfterInterruption() {
        wasInterruptedWhilePlaying = false
        // Reactivating *before* resuming is essential; skipping it is the classic cause
        // of playback that resumes but produces no sound.
        isActivated = false
        activate()
        onResume?()
    }

    func noteIsPlaying(_ isPlaying: Bool) {
        self.isPlaying = isPlaying
        // Playing again -- by any route -- settles the question, so a stale latch cannot
        // restart music minutes later.
        if isPlaying { wasInterruptedWhilePlaying = false }
    }
}
