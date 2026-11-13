import CGtk
import Foundation

/// For layouts that change shape with the window rather than ask for a width of their
/// own: the number of columns, side by side or stacked, what fits in the player bar. A
/// window can be any size, from a phone's width to a whole 2560-pixel screen, so nothing
/// here may ask for more than the narrowest layout needs.
@MainActor
enum Widths {
    /// A one-pixel strip that reports the width it is given whenever it changes; put it in
    /// the box whose width matters. The report comes after the layout pass, so the change
    /// it makes lays out again rather than inside the pass.
    static func watch(_ changed: @escaping @MainActor (Int32) -> Void) -> Widget {
        let sizer = DrawingArea(height: 1) { _, _, _ in }
        sizer.hexpand().canTarget(false)
        var last: Int32 = -1
        sizer.onResize { width, _ in
            guard width > 0, width != last else { return }
            last = width
            Task { @MainActor in changed(width) }
        }
        return sizer
    }
}

extension Widths {
    /// A page's header of a cover beside its title and buttons: the cover above them on a
    /// phone's width. Goes in the same box as the header.
    static func stacking(_ header: Box, cover: Widget, below narrow: Int32 = 560) -> Widget {
        watch { width in
            header.orientation(width < narrow ? GTK_ORIENTATION_VERTICAL : GTK_ORIENTATION_HORIZONTAL)
            cover.halign(width < narrow ? GTK_ALIGN_CENTER : GTK_ALIGN_FILL)
        }
    }
}

/// Tiles in as many equal columns as fit, at least `tileWidth` each and never more than
/// `maxColumns`: four across a wide window, one on a phone.
@MainActor
final class TileGrid {
    let root: Box
    private let grid = Grid(rowSpacing: 10, columnSpacing: 10)
    private let tiles: [Widget]
    private var columns = 0

    init(_ tiles: [Widget], tileWidth: Int32, maxColumns: Int) {
        self.tiles = tiles
        gtk_grid_set_column_homogeneous(grid.widget.cast(), 1)
        let grid = self.grid
        let reference = WeakReference<TileGrid>(nil)
        root = Box.vertical(spacing: 0) {
            Widths.watch { width in
                reference.value?.arrange(columns: max(1, min(maxColumns, Int(width / tileWidth))))
            }
            grid
        }
        reference.value = self
        root.keep(self)
        arrange(columns: 1)
    }

    private func arrange(columns: Int) {
        guard columns != self.columns else { return }
        self.columns = columns
        // Held while they move: the grid lets go of a child it removes.
        let moving = tiles.filter { gtk_widget_get_parent($0.widget) != nil }
        for tile in moving {
            g_object_ref(tile.widget)
            gtk_grid_remove(grid.widget.cast(), tile.widget)
        }
        for (index, tile) in tiles.enumerated() {
            grid.attach(tile, column: Int32(index % columns), row: Int32(index / columns))
        }
        for tile in moving { g_object_unref(tile.widget) }
    }
}
