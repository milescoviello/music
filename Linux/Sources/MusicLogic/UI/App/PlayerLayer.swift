import CGtk
import Foundation

/// The full player over the window, as the phone's comes up over its tabs: sliding up to
/// fill the whole window, its own top bar standing in for the header bar — dragged to move
/// the window, with the window's buttons. The mini player that opens it floats over the
/// pages (`BottomChrome`).
///
/// Not libadwaita's bottom sheet: that leaves a strip of the window above the open sheet
/// which takes every drag (for swiping the sheet closed), so the window could not be
/// moved while the player was up.
@MainActor
final class PlayerLayer {
    let root: Stack
    private var open = false
    private var onOpen: [@MainActor (Bool) -> Void] = []

    init(content: Widget, player playerView: Widget) {
        root = Stack(transition: GTK_STACK_TRANSITION_TYPE_OVER_UP_DOWN)
        gtk_stack_set_hhomogeneous(root.widget.cast(), 0)
        gtk_stack_set_vhomogeneous(root.widget.cast(), 0)
        gtk_stack_set_transition_duration(root.widget.cast(), 250)
        root.add(content.vexpand(), name: "library")
        root.add(playerView, name: "player")
        root.visibleName = "library"
        root.keep(self)
    }

    var isOpen: Bool {
        get { open }
        set { setOpen(newValue) }
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
