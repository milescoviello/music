import CGtk
import Foundation

/// The entry point: a GTK application whose main loop also drains Swift's main actor.
public enum MusicApplication {
    @MainActor
    public static func run() {
        MainLoop.install()
        let state = AppState()
        _ = state
        MainLoop.run()
    }
}
