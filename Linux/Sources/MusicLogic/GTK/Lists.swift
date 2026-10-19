import CGtk
import Foundation

/// A long list or grid that only builds what is on screen: every album in the library,
/// every track, every artist.
///
/// GTK's list views recycle a handful of row widgets as the list scrolls, asking for each
/// to be bound to a different item. The model behind it here is just positions — a
/// `GtkStringList` of "0", "1", "2"… — and the items stay in Swift, so a screen hands over
/// an array and says how to make a row (`setup`) and how to fill one (`bind`).
///
/// A row's Swift side — the handles to its labels and its artwork — is a `Cell` made in
/// `setup` and kept on the list item, so `bind` only sets values.
@MainActor
final class ItemList<Item, Cell: AnyObject> {
    enum Layout {
        case list
        case grid(minColumns: UInt32, maxColumns: UInt32)
    }

    /// The `GtkListView` or `GtkGridView`. Put it directly in a `ScrolledWindow`, which is
    /// what lets it build only the visible rows.
    let view: Widget
    private(set) var items: [Item]
    private let isGrid: Bool
    private let strings: OpaquePointer
    private let setup: @MainActor () -> (Widget, Cell)
    private let bind: @MainActor (Cell, Item, Int) -> Void

    init(
        _ layout: Layout,
        items: [Item] = [],
        setup: @escaping @MainActor () -> (Widget, Cell),
        bind: @escaping @MainActor (Cell, Item, Int) -> Void,
        activate: (@MainActor (Item, Int) -> Void)? = nil
    ) {
        self.items = items
        if case .grid = layout { isGrid = true } else { isGrid = false }
        self.setup = setup
        self.bind = bind
        strings = gtk_string_list_new(nil)
        let selection = gtk_no_selection_new(strings.opaque)!
        let factory = gtk_signal_list_item_factory_new()!

        switch layout {
        case .list:
            view = Widget(gtk_list_view_new(selection.opaque, factory)!)
            gtk_list_view_set_single_click_activate(view.widget.cast(), 1)
        case let .grid(minColumns, maxColumns):
            view = Widget(gtk_grid_view_new(selection.opaque, factory)!)
            gtk_grid_view_set_min_columns(view.widget.cast(), minColumns)
            gtk_grid_view_set_max_columns(view.widget.cast(), maxColumns)
            gtk_grid_view_set_single_click_activate(view.widget.cast(), 1)
        }

        let reference = WeakReference(self)
        Signal.connect(factory, "setup", pointer: { item in
            guard let item, let list = reference.value else { return }
            let (widget, cell) = list.setup()
            gtk_list_item_set_child(OpaquePointer(item), widget.widget)
            retain(cell, on: item, key: "cell")
        })
        Signal.connect(factory, "bind", pointer: { item in
            guard let item, let list = reference.value,
                  let cell = cellOf(item, as: Cell.self),
                  let index = list.index(of: item), index < list.items.count
            else { return }
            list.bind(cell, list.items[index], index)
        })
        if let activate {
            Signal.connect(view.widget, "activate", uint: { position in
                guard let list = reference.value, Int(position) < list.items.count else { return }
                activate(list.items[Int(position)], Int(position))
            })
        }
        view.keep(self)
        set(items)
    }

    private func index(of item: UnsafeMutableRawPointer) -> Int? {
        guard let object = gtk_list_item_get_item(OpaquePointer(item)) else { return nil }
        return Int(String(cString: gtk_string_object_get_string(OpaquePointer(object))))
    }

    /// Replaces the items. Rows on screen are bound again; the scroll position stays.
    func set(_ items: [Item]) {
        let previous = Int(g_list_model_get_n_items(strings.opaque))
        self.items = items
        var values: [UnsafePointer<CChar>?] = []
        var storage: [ContiguousArray<CChar>] = []
        storage.reserveCapacity(items.count)
        for index in items.indices {
            storage.append(ContiguousArray(String(index).utf8CString))
        }
        values = storage.map { $0.withUnsafeBufferPointer { $0.baseAddress } }
        values.append(nil)
        values.withUnsafeMutableBufferPointer { buffer in
            gtk_string_list_splice(strings, 0, guint(previous), buffer.baseAddress)
        }
        withExtendedLifetime(storage) {}
    }

    /// Scrolls so the item at `index` is in view.
    func scroll(to index: Int) {
        guard index >= 0, index < items.count else { return }
        if isGrid {
            gtk_grid_view_scroll_to(view.widget.cast(), guint(index), GTK_LIST_SCROLL_NONE, nil)
        } else {
            gtk_list_view_scroll_to(view.widget.cast(), guint(index), GTK_LIST_SCROLL_NONE, nil)
        }
    }
}

/// Keeps `object` on a GObject under a name, so it can be looked up again.
@MainActor
func retain(_ object: AnyObject, on owner: GPointer, key: String) {
    let destroy: GDestroyNotify = { data in
        guard let data else { return }
        Unmanaged<AnyObject>.fromOpaque(data).release()
    }
    g_object_set_data_full(owner.gobject, key, Unmanaged.passRetained(object).toOpaque(), destroy)
}

@MainActor
private func cellOf<Cell: AnyObject>(_ item: UnsafeMutableRawPointer, as _: Cell.Type) -> Cell? {
    guard let data = g_object_get_data(item.assumingMemoryBound(to: GObject.self), "cell") else { return nil }
    return Unmanaged<AnyObject>.fromOpaque(data).takeUnretainedValue() as? Cell
}

/// A list of a few hundred rows at most, built all at once: an album's tracks, a
/// playlist, settings. Styled as GNOME's boxed list or as a plain list.
final class ListBox: Widget {
    private var activations: [@MainActor () -> Void] = []

    init(boxed: Bool = true) {
        super.init(gtk_list_box_new()!)
        gtk_list_box_set_selection_mode(widget.cast(), GTK_SELECTION_NONE)
        if boxed { css("boxed-list") }
        let reference = WeakReference(self)
        Signal.connect(widget, "row-activated", pointer: { row in
            guard let row, let list = reference.value else { return }
            let index = Int(gtk_list_box_row_get_index(row.assumingMemoryBound(to: GtkListBoxRow.self)))
            if index >= 0, index < list.activations.count { list.activations[index]() }
        })
        keep(self)
    }

    /// A row, activated by click or Enter if `activate` is given.
    @discardableResult
    func append(_ child: Widget, activate: (@MainActor () -> Void)? = nil) -> Self {
        gtk_list_box_append(widget.cast(), child.widget)
        if let row = gtk_list_box_get_row_at_index(widget.cast(), Int32(activations.count)) {
            gtk_list_box_row_set_activatable(row, activate == nil ? 0 : 1)
        }
        activations.append(activate ?? {})
        return self
    }

    func removeAll() {
        gtk_list_box_remove_all(widget.cast())
        activations.removeAll()
    }

    /// Shown when the list has no rows.
    @discardableResult
    func placeholder(_ child: Widget) -> Self {
        gtk_list_box_set_placeholder(widget.cast(), child.widget)
        return self
    }
}
