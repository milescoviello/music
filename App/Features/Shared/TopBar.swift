import SwiftUI

extension View {
    /// A row pinned under the navigation bar -- a picker, say.
    ///
    /// From iOS 26 it floats over the page with nothing behind it, as the tab bar and the
    /// mini player do: its controls are glass already. A material behind it was a grey band
    /// across the cover's tint (2026-11-25), and the system's bar slot, `safeAreaBar`,
    /// blurred the large title above it. Before 26 the material keeps scrolled rows from
    /// showing through, held to the row's own frame: let into the safe area, it rose over
    /// the navigation bar and hid the title.
    func topBar<Bar: View>(@ViewBuilder _ bar: () -> Bar) -> some View {
        modifier(TopBarModifier(bar: bar()))
    }

    /// The glass a control in a `topBar` floats on from iOS 26. A segmented picker's own
    /// track is nearly clear, and rows scrolled under it read through its labels.
    @ViewBuilder
    func topBarGlass() -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular, in: .capsule)
        } else {
            self
        }
    }
}

private struct TopBarModifier<Bar: View>: ViewModifier {
    let bar: Bar

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.safeAreaInset(edge: .top, spacing: 0) { bar }
        } else {
            content.safeAreaInset(edge: .top, spacing: 0) {
                bar.background(.bar, ignoresSafeAreaEdges: [])
            }
        }
    }
}
