import CGtk
import Foundation

/// Dragging rows to reorder them: the queue, a playlist, the playlist list. Each row is a
/// drag source carrying its place as a string, and a drop target that moves whatever is
/// dropped on it to where it is. GTK draws the target under the pointer (`:drop(active)`).
extension Widget {
    /// Dragged, it carries `payload`, and looks like itself under the pointer.
    @discardableResult
    func draggable(_ payload: String) -> Self {
        let source = gtk_drag_source_new()!
        gtk_drag_source_set_actions(source, GDK_ACTION_MOVE)
        if let content = cgtk_string_provider(payload) {
            gtk_drag_source_set_content(source, content)
            g_object_unref(content)
        }
        let pointer = widget
        Signal.connect(source, "drag-begin", pointer: { _ in
            let paintable = gtk_widget_paintable_new(pointer)
            gtk_drag_source_set_icon(source, paintable, 24, 12)
            if let paintable { g_object_unref(UnsafeMutableRawPointer(paintable)) }
        })
        gtk_widget_add_controller(widget, source)
        return self
    }

    /// What is dropped on it, as the string it carried: true when taken.
    @discardableResult
    func onDrop(_ handler: @escaping @MainActor (String) -> Bool) -> Self {
        let target = gtk_drop_target_new(cgtk_gtype_string(), GDK_ACTION_MOVE)!
        Signal.connect(target, "drop", drop: handler)
        gtk_widget_add_controller(widget, target)
        return self
    }
}
