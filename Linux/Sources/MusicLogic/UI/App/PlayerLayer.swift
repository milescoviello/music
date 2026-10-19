import CGtk
import Foundation

/// The player over the window, Plexamp's way: the mini player along the bottom while
/// browsing, and the full player sliding up to fill the whole window, its own top bar
/// standing in for the header bar — dragged to move the window, with the window's buttons.
///
/// Not libadwaita's bottom sheet: that leaves a strip of the window above the open sheet
/// which takes every drag (for swiping the sheet closed), so the window could not be
/// moved while the player was up.
///
/// The two are pages of a stack that is not homogeneous, so only the one showing sets the
/// window's smallest size: the library's layout does not stop the player being shrunk to
/// the tiny window Plexamp allows.
@MainActor
final class PlayerLayer {
    let root: Stack
    private let bar: Revealer
    private var open = false
    private var onOpen: [@MainActor (Bool) -> Void] = []

    init(content: Widget, player playerView: Widget, bar barView: Widget) {
        let bar = Revealer(barView, transition: GTK_REVEALER_TRANSITION_TYPE_SLIDE_UP)
        root = Stack(transition: GTK_STACK_TRANSITION_TYPE_OVER_UP_DOWN)
        gtk_stack_set_hhomogeneous(root.widget.cast(), 0)
        gtk_stack_set_vhomogeneous(root.widget.cast(), 0)
        gtk_stack_set_transition_duration(root.widget.cast(), 250)
        // The bar below the pages rather than over them, so the end of a list is never
        // hidden under it.
        root.add(Box.vertical {
            content.vexpand()
            bar
        }, name: "library")
        root.add(playerView, name: "player")
        root.visibleName = "library"
        self.bar = bar

        // The bar opens the player wherever it is clicked that is not one of its buttons;
        // a button's own click claims the press first.
        let reference = WeakReference<PlayerLayer>(nil)
        barView.onClick { reference.value?.setOpen(true) }
        reference.value = self
        root.keep(self)
    }

    var isOpen: Bool {
        get { open }
        set { setOpen(newValue) }
    }

    /// Whether the mini player shows: only while there is something to play.
    var revealsBar: Bool {
        get { bar.isRevealed }
        set { bar.isRevealed = newValue }
    }

    var canOpen = true

    func onOpenChanged(_ action: @escaping @MainActor (Bool) -> Void) {
        onOpen.append(action)
    }

    private func setOpen(_ open: Bool) {
        guard open != self.open, !open || canOpen else { return }
        self.open = open
        gtk_stack_set_transition_type(
            root.widget.cast(), open ? GTK_STACK_TRANSITION_TYPE_OVER_UP : GTK_STACK_TRANSITION_TYPE_UNDER_DOWN
        )
        root.visibleName = open ? "player" : "library"
        for action in onOpen { action(open) }
    }
}
