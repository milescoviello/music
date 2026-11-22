#if canImport(BackgroundTasks)
import BackgroundTasks
import Foundation

/// Overnight, on the charger with a network: what the app does while it is open, done while
/// it isn't -- what is owed sent, downloaded playlists followed, the most played downloaded,
/// every download's lyrics, translation and covers filled in -- so the phone is ready before
/// leaving the house. Before, all of it waited for the app to be opened ("300 to fetch,
/// waiting for a charger", with the phone on one all night).
@MainActor
enum OvernightSync {
    static let identifier = "com.milescoviello.music.overnight"

    /// At launch, before it finishes: iOS refuses a registration after.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            MainActor.assumeIsolated { run(task) }
        }
    }

    /// Asked for each time the app goes to the background, and again after each run.
    static func schedule() {
        let request = BGProcessingTaskRequest(identifier: identifier)
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = true
        request.earliestBeginDate = OvernightWindow.next(after: .now)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            Task { await Diagnostics.shared.record("app", "overnight sync not scheduled: \(error.localizedDescription)") }
        }
    }

    private static func run(_ task: BGTask) {
        schedule()
        guard let appState = MusicIntentBridge.appState else {
            task.setTaskCompleted(success: false)
            return
        }
        let work = Task { @MainActor in
            let done = await appState.overnightSync()
            task.setTaskCompleted(success: done)
        }
        task.expirationHandler = { work.cancel() }
    }
}
#endif
