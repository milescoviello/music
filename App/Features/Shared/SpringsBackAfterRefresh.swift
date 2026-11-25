import SwiftUI

extension View {
    /// Pull to refresh that lets go of the page at once. Attach to the scroll view itself.
    ///
    /// The pull starts the work and ends there and then, so the page springs straight back
    /// the way any scroll view does; the work goes on in a task of its own. `settled`,
    /// handed to it, waits for the page to come to rest at the top: what was fetched is
    /// shown after that.
    ///
    /// Why: holding the refresh while Home loaded, the page sat pulled down with no spinner
    /// to be seen, and when the refresh ended its shelves changed height at the same
    /// moment, which left the page stuck past its top -- "animating" and never moving,
    /// until touched (measured in the simulator: offset -228 left against an inset of 168).
    /// A change at rest is harmless.
    ///
    /// Should anything else leave the page past its top with no finger on it, it is put
    /// back -- a scroll view left alone is never there otherwise.
    func refreshableSpringingBack(
        _ action: @escaping @Sendable (_ settled: @escaping @MainActor @Sendable () async -> Void) async -> Void
    ) -> some View {
        modifier(SpringingRefresh(action: action))
    }
}

private struct SpringingRefresh: ViewModifier {
    let action: @Sendable (_ settled: @escaping @MainActor @Sendable () async -> Void) async -> Void

    @State private var position = ScrollPosition(edge: .top)
    @State private var scroll = ScrollState()

    func body(content: Content) -> some View {
        content
            .refreshable {
                // Not awaited: holding the refresh is what held the page down.
                let scroll = scroll
                scroll.pulledAt = .now
                Task { await action { await scroll.waitUntilSettled() } }
            }
            .scrollPosition($position)
            .onScrollPhaseChange { _, phase in
                scroll.phase = phase
                check()
            }
            // A Bool, not the offset: this fires at display rate while scrolling, and only a
            // change of answer gets through.
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top < -1
            } action: { _, past in
                scroll.isPastTop = past
                check()
            }
    }

    /// The backstop. Stuck, the page says it is animating and never moves, so the test is
    /// time rather than rest: still past the top with no finger on it after longer than
    /// any spring back takes.
    private func check() {
        scroll.settling?.cancel()
        guard scroll.isStuck else { return }
        scroll.settling = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, scroll.isStuck else { return }
            await Diagnostics.shared.record("refresh", "the page was left past its top: put back")
            withAnimation(.smooth(duration: 0.35)) {
                position.scrollTo(edge: .top)
            }
        }
    }
}

/// Where the scroll view is, kept out of SwiftUI's sight: a plain object, so following
/// the scrolling redraws nothing.
@MainActor
private final class ScrollState {
    var phase: ScrollPhase = .idle
    var isPastTop = false
    var pulledAt: Date?
    var settling: Task<Void, Never>?

    /// Past the top with no finger on it. A flick past the top passes through here too,
    /// for the moment its spring back takes.
    var isStuck: Bool { isPastTop && phase != .tracking && phase != .interacting }

    /// At rest, at the top, the finger lifted; or three seconds, whichever is first, so a
    /// finger left on the glass doesn't hold the new shelves back for ever.
    func waitUntilSettled() async {
        let start = ContinuousClock.now
        // The pull itself first: the system ends the refresh as the work starts.
        try? await Task.sleep(for: .milliseconds(80))
        while !(phase == .idle && !isPastTop), ContinuousClock.now - start < .seconds(3) {
            try? await Task.sleep(for: .milliseconds(40))
        }
    }
}
