import CGtk
import Foundation

/// A popover menu built from Swift closures: GTK's native menu, with its keyboard handling
/// and look, without declaring application-wide actions for every row of every list.
///
/// Each menu gets its own action group, inserted into the popover it opens, so its
/// actions live and die with that one popover. Menus are built when opened rather than
/// when the screen is, so what they say — Favourite or Unfavourite, Download or Remove —
/// is true at the moment they are read.
@MainActor
struct Menu {
    enum Item {
        case action(String, destructive: Bool = false, enabled: Bool = true, @MainActor () -> Void)
        /// A checkbox.
        case toggle(String, isOn: Bool, @MainActor (Bool) -> Void)
        /// A submenu of radio items; the chosen option's id comes back.
        case choice(String, options: [(id: String, label: String)], selected: String?, @MainActor (String) -> Void)
        case submenu(String, [[Item]])
    }

    var sections: [[Item]]

    init(_ sections: [[Item]]) {
        self.sections = sections.filter { !$0.isEmpty }
    }

    /// Opens the menu pointing at a point in `widget`, or at all of it.
    func popup(at widget: Widget, x: Double? = nil, y: Double? = nil) {
        guard !sections.isEmpty else { return }
        let group = g_simple_action_group_new()!
        var counter = 0
        let model = Self.model(for: sections, group: group, counter: &counter)

        let popover = gtk_popover_menu_new_from_model(model.rawPointer.assumingMemoryBound(to: GMenuModel.self))!
        g_object_unref(model.rawPointer)
        gtk_widget_insert_action_group(popover, "menu", group.opaque)
        g_object_unref(group.rawPointer)

        gtk_widget_set_parent(popover, widget.widget)
        if let x, let y {
            var point = GdkRectangle(x: Int32(x), y: Int32(y), width: 1, height: 1)
            gtk_popover_set_pointing_to(popover.cast(), &point)
            gtk_popover_set_has_arrow(popover.cast(), 0)
            gtk_widget_set_halign(popover, GTK_ALIGN_START)
        }
        // Unparented once closed, on the next turn: GTK is still finishing the close.
        Signal.connect(popover, "closed") {
            let pointer = Unchecked(popover)
            Task { @MainActor in gtk_widget_unparent(pointer.value) }
        }
        gtk_popover_popup(popover.cast())
    }

    private static func model(for sections: [[Item]], group: UnsafeMutablePointer<GSimpleActionGroup>, counter: inout Int) -> OpaquePointer {
        let menu = g_menu_new()!
        for section in sections {
            let part = g_menu_new()!
            for item in section {
                append(item, to: part, group: group, counter: &counter)
            }
            g_menu_append_section(menu, nil, part.rawPointer.assumingMemoryBound(to: GMenuModel.self))
            g_object_unref(part.rawPointer)
        }
        return menu
    }

    private static func append(_ item: Item, to menu: OpaquePointer, group: UnsafeMutablePointer<GSimpleActionGroup>, counter: inout Int) {
        counter += 1
        let name = "item\(counter)"
        let map = group.opaque

        switch item {
        case let .action(title, destructive, enabled, handler):
            let action = g_simple_action_new(name, nil)!
            g_simple_action_set_enabled(action, enabled ? 1 : 0)
            Signal.connect(action, "activate", pointer: { _ in handler() })
            g_action_map_add_action(map, action.opaque)
            g_object_unref(action.rawPointer)
            let entry = g_menu_item_new(title, "menu.\(name)")!
            if destructive {
                g_menu_item_set_attribute_value(entry, "css-class", g_variant_new_string("error"))
            }
            g_menu_append_item(menu, entry)
            g_object_unref(entry.rawPointer)

        case let .toggle(title, isOn, handler):
            let action = g_simple_action_new_stateful(name, nil, g_variant_new_boolean(isOn ? 1 : 0))!
            Signal.connect(action, "activate", pointer: { _ in
                let state = g_action_get_state(action.opaque)
                let current = state.map { g_variant_get_boolean($0) != 0 } ?? isOn
                if let state { g_variant_unref(state) }
                g_simple_action_set_state(action, g_variant_new_boolean(current ? 0 : 1))
                handler(!current)
            })
            g_action_map_add_action(map, action.opaque)
            g_object_unref(action.rawPointer)
            g_menu_append(menu, title, "menu.\(name)")

        case let .choice(title, options, selected, handler):
            let action = g_simple_action_new_stateful(name, cgtk_variant_type("s"), g_variant_new_string(selected ?? ""))!
            Signal.connect(action, "activate", pointer: { parameter in
                guard let parameter else { return }
                let value = OpaquePointer(parameter)
                let id = String(cString: g_variant_get_string(value, nil))
                g_simple_action_set_state(action, g_variant_new_string(id))
                handler(id)
            })
            g_action_map_add_action(map, action.opaque)
            g_object_unref(action.rawPointer)
            let submenu = g_menu_new()!
            for option in options {
                let entry = g_menu_item_new(option.label, nil)!
                g_menu_item_set_action_and_target_value(entry, "menu.\(name)", g_variant_new_string(option.id))
                g_menu_append_item(submenu, entry)
                g_object_unref(entry.rawPointer)
            }
            g_menu_append_submenu(menu, title, submenu.rawPointer.assumingMemoryBound(to: GMenuModel.self))
            g_object_unref(submenu.rawPointer)

        case let .submenu(title, sections):
            let submenu = model(for: sections, group: group, counter: &counter)
            g_menu_append_submenu(menu, title, submenu.rawPointer.assumingMemoryBound(to: GMenuModel.self))
            g_object_unref(submenu.rawPointer)
        }
    }
}

/// A button that opens a menu built at the moment it is pressed.
final class MenuButton: Widget {
    init(icon: String = "view-more-symbolic", label: String? = nil, _ classes: String..., menu: @escaping @MainActor () -> Menu) {
        super.init(gtk_button_new()!)
        if let label {
            let content = adw_button_content_new()!
            adw_button_content_set_label(content.cast(), label)
            adw_button_content_set_icon_name(content.cast(), icon)
            gtk_button_set_child(widget.cast(), content)
        } else {
            gtk_button_set_icon_name(widget.cast(), icon)
        }
        for name in classes { gtk_widget_add_css_class(widget, name) }
        let reference = WeakReference(self)
        Signal.connect(widget, "clicked") {
            guard let button = reference.value else { return }
            menu().popup(at: button)
        }
        keep(self)
    }
}

extension Widget {
    /// A context menu on right click or long press, built when it opens.
    @discardableResult
    func contextMenu(_ menu: @escaping @MainActor () -> Menu?) -> Self {
        // The gesture belongs to the widget, so the widget exists whenever it fires.
        let pointer = widget
        onContextClick { x, y in
            guard let built = menu() else { return }
            built.popup(at: Widget(pointer), x: x, y: y)
        }
        return self
    }
}
