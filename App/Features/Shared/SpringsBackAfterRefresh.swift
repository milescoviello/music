import SwiftUI

extension View {
    /// `.refreshable` that always lets go of the page. Attach to the scroll view itself.
    ///
    /// When a refresh ends, the system takes back the room it made for the spinner. If the
    /// page's height changes at that moment -- Home's shelves do, as they come back -- the
    /// inset goes but the scroll offset stays: the page held down under an empty band,
    /// "animating" and never moving, until it is touched again. Measured in the simulator:
    /// offset -228 left against an inset of 168. A scroll view left alone is never past
    /// its top otherwise, so finding it there puts it back.
    ///
    /// The work runs in a task of its own: a change to the page's state while it runs
    /// can make SwiftUI cancel the refresh's task, and the load with it -- which, through
    /// the saved copies, finishes at once having fetched nothing.
    func refreshableSpringingBack(_ action: @escaping @Sendable () async -> Void) -> some View {
        modifier(SpringingRefresh(action: action))
    }
}

private struct SpringingRefresh: ViewModifier {
    let action: @Sendable () async -> Void

    @State private var position = ScrollPosition(edge: .top)
    @State private var scroll = ScrollState()

    func body(content: Content) -> some View {
        content
            .refreshable {
                scroll.isRefreshing = true
                await Task { await action() }.value
                scroll.isRefreshing = false
                check()
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

    /// Stuck, it says it is animating and never moves, so the test is time rather than
    /// rest: still past the top with no finger on it after longer than any spring back
    /// takes.
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
/// the scrolling redraws nothing, and nothing changes the page while a refresh runs.
@MainActor
private final class ScrollState {
    var phase: ScrollPhase = .idle
    var isPastTop = false
    var isRefreshing = false
    var settling: Task<Void, Never>?

    /// Past the top with no finger on it and no refresh holding it there. A flick past the
    /// top passes through here too, for the moment its spring back takes.
    var isStuck: Bool { isPastTop && phase != .tracking && phase != .interacting && !isRefreshing }
}
