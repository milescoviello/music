import Observation

/// SwiftUI's one trick, for GTK: run some code that reads observable state, and run it
/// again whenever any of what it read changes.
///
/// `withObservationTracking` reports a change once, before it happens, from whatever
/// thread made it; the re-run is posted to the main actor so it reads the new values,
/// and several changes in one turn cost one re-run. Each run re-registers whatever it
/// read that time, so a branch not taken is not watched.
///
/// An observer belongs to a widget (`Widget.observe`) and stops when the widget is
/// finalized: it is released, and a pending re-run finds nothing to run.
@MainActor
final class Observer {
    private var body: (@MainActor () -> Void)?

    /// How many observers are running their body right now, one inside another.
    private static var depth = 0

    /// Runs `body` now, or, when made while another observer's body is running, just after.
    ///
    /// Observation merges what a nested tracking read into the one around it, so a row
    /// bound while a page built itself made the page watch the player, the downloads and
    /// the stars: every song change, star and finished download rebuilt the whole page
    /// (a scrolled shelf jumped back to its start; an open mix grew by 50 songs a track).
    init(_ body: @escaping @MainActor () -> Void) {
        self.body = body
        if Self.depth > 0 {
            let reference = WeakReference(self)
            Task { @MainActor in reference.value?.run() }
        } else {
            run()
        }
    }

    func cancel() {
        body = nil
    }

    private func run() {
        guard let body else { return }
        let reference = WeakReference(self)
        Self.depth += 1
        defer { Self.depth -= 1 }
        withObservationTracking {
            body()
        } onChange: {
            Task { @MainActor in reference.value?.run() }
        }
    }
}

/// A weak reference that may cross into a `@Sendable` closure.
final class WeakReference<Object: AnyObject>: @unchecked Sendable {
    weak var value: Object?

    init(_ value: Object?) {
        self.value = value
    }
}
