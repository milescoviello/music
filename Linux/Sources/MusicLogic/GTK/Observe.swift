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

    init(_ body: @escaping @MainActor () -> Void) {
        self.body = body
        run()
    }

    func cancel() {
        body = nil
    }

    private func run() {
        guard let body else { return }
        let reference = WeakReference(self)
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
