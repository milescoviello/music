import Intents
import UIKit

/// Exists for the two callbacks SwiftUI has no equivalent for:
/// `handleEventsForBackgroundURLSession`, and which way the screen may turn -- upright
/// everywhere but a full-screen video (`VideoOrientation`).
///
/// When downloads finish while the app is not running, iOS relaunches it in the
/// background purely to deliver those events, hands over a completion handler, and
/// expects it to be called once the session says it is done. An app that fails to
/// call it gets relaunched less and less often — so downloads degrade quietly rather
/// than visibly, which is the worst possible failure mode for this feature.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        BackgroundSessionBridge.pendingCompletion = completionHandler
    }

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        MainActor.assumeIsolated { VideoOrientation.mask }
    }

    /// Siri's "play <something>" (`SiriPlayMedia`), handled in the app rather than in an
    /// extension: the player is here.
    func application(_ application: UIApplication, handlerFor intent: INIntent) -> Any? {
        intent is INPlayMediaIntent ? SiriPlayMedia() : nil
    }

    /// The second half: Siri found it and answered "in the app", and the system has woken
    /// the app, with leave to start audio, to play it.
    func application(
        _ application: UIApplication,
        handle intent: INIntent,
        completionHandler: @escaping (INIntentResponse) -> Void
    ) {
        guard let request = intent as? INPlayMediaIntent, let identifier = request.mediaItems?.first?.identifier else {
            completionHandler(INPlayMediaIntentResponse(code: .failure, userActivity: nil))
            return
        }
        let shuffled = request.playShuffled == true
        Task { @MainActor in
            let played = await SiriPlayMedia.play(identifier, shuffled: shuffled)
            completionHandler(INPlayMediaIntentResponse(code: played ? .success : .failure, userActivity: nil))
        }
    }
}

/// A static hand-off, because the relaunch can arrive before any `AppState` exists —
/// there is nothing to inject into yet, and the session that will report the events
/// is recreated from its identifier rather than from anything the UI owns.
@MainActor
enum BackgroundSessionBridge {
    static var pendingCompletion: (() -> Void)?

    static func finish() {
        let handler = pendingCompletion
        pendingCompletion = nil
        handler?()
    }
}
