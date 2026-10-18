import CGtk
import Foundation

/// A handle on a GTK widget, with the modifiers every screen uses.
///
/// Handles do not own their widgets — the widget tree does, as GTK intends — so building a
/// screen is making handles, nesting them, and letting them go. A Swift object that must
/// live as long as a widget is attached to it (`keep`), and an observer or a signal handler
/// lives exactly as long as the widget it was added to. That is the whole memory model:
/// nothing outlives its widget, and no widget is kept alive by Swift.
///
/// Modifiers return `Self`, so a widget is configured where it is made.
@MainActor
class Widget {
    let widget: UnsafeMutablePointer<GtkWidget>

    init(_ pointer: GPointer) {
        widget = pointer.cast()
    }

    // MARK: Layout

    @discardableResult
    func margin(_ value: Int32) -> Self {
        margins(top: value, bottom: value, start: value, end: value)
    }

    @discardableResult
    func margin(horizontal: Int32 = 0, vertical: Int32 = 0) -> Self {
        margins(top: vertical, bottom: vertical, start: horizontal, end: horizontal)
    }

    @discardableResult
    func margins(top: Int32? = nil, bottom: Int32? = nil, start: Int32? = nil, end: Int32? = nil) -> Self {
        if let top { gtk_widget_set_margin_top(widget, top) }
        if let bottom { gtk_widget_set_margin_bottom(widget, bottom) }
        if let start { gtk_widget_set_margin_start(widget, start) }
        if let end { gtk_widget_set_margin_end(widget, end) }
        return self
    }

    @discardableResult
    func hexpand(_ value: Bool = true) -> Self {
        gtk_widget_set_hexpand(widget, value ? 1 : 0)
        return self
    }

    @discardableResult
    func vexpand(_ value: Bool = true) -> Self {
        gtk_widget_set_vexpand(widget, value ? 1 : 0)
        return self
    }

    @discardableResult
    func halign(_ align: GtkAlign) -> Self {
        gtk_widget_set_halign(widget, align)
        return self
    }

    @discardableResult
    func valign(_ align: GtkAlign) -> Self {
        gtk_widget_set_valign(widget, align)
        return self
    }

    /// A minimum size; -1 leaves a dimension natural.
    @discardableResult
    func size(width: Int32 = -1, height: Int32 = -1) -> Self {
        gtk_widget_set_size_request(widget, width, height)
        return self
    }

    @discardableResult
    func css(_ names: String...) -> Self {
        for name in names { gtk_widget_add_css_class(widget, name) }
        return self
    }

    func setCSS(_ name: String, _ on: Bool) {
        if on {
            gtk_widget_add_css_class(widget, name)
        } else {
            gtk_widget_remove_css_class(widget, name)
        }
    }

    @discardableResult
    func name(_ name: String) -> Self {
        gtk_widget_set_name(widget, name)
        return self
    }

    @discardableResult
    func tooltip(_ text: String?) -> Self {
        gtk_widget_set_tooltip_text(widget, text)
        return self
    }

    var isVisible: Bool {
        get { gtk_widget_get_visible(widget) != 0 }
        set { gtk_widget_set_visible(widget, newValue ? 1 : 0) }
    }

    var isSensitive: Bool {
        get { gtk_widget_get_sensitive(widget) != 0 }
        set { gtk_widget_set_sensitive(widget, newValue ? 1 : 0) }
    }

    @discardableResult
    func visible(_ value: Bool) -> Self {
        isVisible = value
        return self
    }

    @discardableResult
    func sensitive(_ value: Bool) -> Self {
        isSensitive = value
        return self
    }

    @discardableResult
    func opacity(_ value: Double) -> Self {
        gtk_widget_set_opacity(widget, value)
        return self
    }

    @discardableResult
    func focusable(_ value: Bool) -> Self {
        gtk_widget_set_focusable(widget, value ? 1 : 0)
        return self
    }

    @discardableResult
    func canTarget(_ value: Bool) -> Self {
        gtk_widget_set_can_target(widget, value ? 1 : 0)
        return self
    }

    /// Clips children to this widget's rounded corners, for artwork.
    @discardableResult
    func clipped() -> Self {
        gtk_widget_set_overflow(widget, GTK_OVERFLOW_HIDDEN)
        return self
    }

    var width: Int32 { gtk_widget_get_width(widget) }
    var height: Int32 { gtk_widget_get_height(widget) }

    func queueDraw() {
        gtk_widget_queue_draw(widget)
    }

    func grabFocus() {
        gtk_widget_grab_focus(widget)
    }

    /// Removes this widget from whatever contains it.
    func unparent() {
        gtk_widget_unparent(widget)
    }

    // MARK: Lifetime and state

    /// Asked by async work before it touches this widget again; see `WeakObject.isAlive`.
    var liveness: WeakObject {
        WeakObject(widget)
    }

    /// Keeps `object` alive for as long as this widget exists.
    @discardableResult
    func keep(_ object: AnyObject) -> Self {
        retain(object, on: widget)
        return self
    }

    /// Runs `body` now and whenever observable state it read changes, for as long as this
    /// widget exists.
    @discardableResult
    func observe(_ body: @escaping @MainActor () -> Void) -> Self {
        keep(Observer(body))
    }

    // MARK: Events

    /// A primary click or tap anywhere in the widget.
    @discardableResult
    func onClick(_ action: @escaping @MainActor () -> Void) -> Self {
        let gesture = gtk_gesture_click_new()!
        gtk_gesture_single_set_button(gesture.cast(), 1)
        Signal.connect(gesture, "released", press: { _, _, _ in action() })
        gtk_widget_add_controller(widget, gesture.cast())
        return self
    }

    /// A right click, or a long press on a touchscreen: the context menu's trigger. The
    /// point is in this widget's coordinates.
    @discardableResult
    func onContextClick(_ action: @escaping @MainActor (Double, Double) -> Void) -> Self {
        let click = gtk_gesture_click_new()!
        gtk_gesture_single_set_button(click.cast(), 3)
        Signal.connect(click, "pressed", press: { _, x, y in action(x, y) })
        gtk_widget_add_controller(widget, click.cast())

        let press = gtk_gesture_long_press_new()!
        gtk_gesture_single_set_touch_only(press.cast(), 1)
        Signal.connect(press, "pressed", point: { x, y in action(x, y) })
        gtk_widget_add_controller(widget, press.cast())
        return self
    }

    /// The pointer entering (true) and leaving (false).
    @discardableResult
    func onHover(_ action: @escaping @MainActor (Bool) -> Void) -> Self {
        let motion = gtk_event_controller_motion_new()!
        Signal.connect(motion, "enter", point: { _, _ in action(true) })
        Signal.connect(motion, "leave") { action(false) }
        gtk_widget_add_controller(widget, motion)
        return self
    }

    /// Runs when the widget is shown on screen, and again each time it comes back: a page
    /// pushed over and popped back to, a tab selected.
    @discardableResult
    func onMap(_ action: @escaping @MainActor () -> Void) -> Self {
        Signal.connect(widget, "map", action)
        return self
    }

    @discardableResult
    func onUnmap(_ action: @escaping @MainActor () -> Void) -> Self {
        Signal.connect(widget, "unmap", action)
        return self
    }
}

/// Children, written as a list in braces.
@MainActor
@resultBuilder
enum WidgetBuilder {
    static func buildBlock(_ parts: [Widget]...) -> [Widget] { parts.flatMap { $0 } }
    static func buildExpression(_ widget: Widget) -> [Widget] { [widget] }
    static func buildExpression(_ widgets: [Widget]) -> [Widget] { widgets }
    static func buildExpression(_ widget: Widget?) -> [Widget] { widget.map { [$0] } ?? [] }
    static func buildOptional(_ part: [Widget]?) -> [Widget] { part ?? [] }
    static func buildEither(first part: [Widget]) -> [Widget] { part }
    static func buildEither(second part: [Widget]) -> [Widget] { part }
    static func buildArray(_ parts: [[Widget]]) -> [Widget] { parts.flatMap { $0 } }
}

// MARK: - Containers

final class Box: Widget {
    init(_ orientation: GtkOrientation = GTK_ORIENTATION_VERTICAL, spacing: Int32 = 0, @WidgetBuilder _ content: () -> [Widget] = { [] }) {
        super.init(gtk_box_new(orientation, spacing)!)
        for child in content() { append(child) }
    }

    static func vertical(spacing: Int32 = 0, @WidgetBuilder _ content: () -> [Widget] = { [] }) -> Box {
        Box(GTK_ORIENTATION_VERTICAL, spacing: spacing, content)
    }

    static func horizontal(spacing: Int32 = 0, @WidgetBuilder _ content: () -> [Widget] = { [] }) -> Box {
        Box(GTK_ORIENTATION_HORIZONTAL, spacing: spacing, content)
    }

    @discardableResult
    func append(_ child: Widget) -> Self {
        gtk_box_append(widget.cast(), child.widget)
        return self
    }

    func prepend(_ child: Widget) {
        gtk_box_prepend(widget.cast(), child.widget)
    }

    func remove(_ child: Widget) {
        gtk_box_remove(widget.cast(), child.widget)
    }

    func removeAll() {
        while let child = gtk_widget_get_first_child(widget) {
            gtk_box_remove(widget.cast(), child)
        }
    }

    /// Replaces every child.
    func set(@WidgetBuilder _ content: () -> [Widget]) {
        removeAll()
        for child in content() { append(child) }
    }

    @discardableResult
    func homogeneous(_ value: Bool = true) -> Self {
        gtk_box_set_homogeneous(widget.cast(), value ? 1 : 0)
        return self
    }
}

final class ScrolledWindow: Widget {
    init(_ child: Widget? = nil, horizontal: GtkPolicyType = GTK_POLICY_NEVER, vertical: GtkPolicyType = GTK_POLICY_AUTOMATIC) {
        super.init(gtk_scrolled_window_new()!)
        gtk_scrolled_window_set_policy(widget.cast(), horizontal, vertical)
        if let child { self.child = child }
    }

    var child: Widget? {
        get { gtk_scrolled_window_get_child(widget.cast()).map(Widget.init) }
        set { gtk_scrolled_window_set_child(widget.cast(), newValue?.widget) }
    }

    /// Takes the child's height rather than expanding, for a scroller inside a page.
    @discardableResult
    func propagatesNaturalHeight(_ value: Bool = true) -> Self {
        gtk_scrolled_window_set_propagate_natural_height(widget.cast(), value ? 1 : 0)
        return self
    }

    @discardableResult
    func propagatesNaturalWidth(_ value: Bool = true) -> Self {
        gtk_scrolled_window_set_propagate_natural_width(widget.cast(), value ? 1 : 0)
        return self
    }

    var verticalAdjustment: UnsafeMutablePointer<GtkAdjustment> {
        gtk_scrolled_window_get_vadjustment(widget.cast())
    }

    var horizontalAdjustment: UnsafeMutablePointer<GtkAdjustment> {
        gtk_scrolled_window_get_hadjustment(widget.cast())
    }

    /// Fires when scrolled within `margin` pixels of the bottom: the trigger for loading
    /// the next page of a long list.
    @discardableResult
    func onNearEnd(margin: Double = 600, _ action: @escaping @MainActor () -> Void) -> Self {
        let adjustment = verticalAdjustment
        Signal.connect(adjustment, "value-changed") { () -> Void in
            let value = gtk_adjustment_get_value(adjustment)
            let upper = gtk_adjustment_get_upper(adjustment)
            let page = gtk_adjustment_get_page_size(adjustment)
            if upper > page, value + page >= upper - margin { action() }
        }
        return self
    }

    func scrollToTop() {
        gtk_adjustment_set_value(verticalAdjustment, 0)
    }
}

final class Overlay: Widget {
    init(_ base: Widget? = nil) {
        super.init(gtk_overlay_new()!)
        if let base { gtk_overlay_set_child(widget.cast(), base.widget) }
    }

    @discardableResult
    func add(_ overlay: Widget) -> Self {
        gtk_overlay_add_overlay(widget.cast(), overlay.widget)
        return self
    }

    var child: Widget? {
        get { gtk_overlay_get_child(widget.cast()).map(Widget.init) }
        set { gtk_overlay_set_child(widget.cast(), newValue?.widget) }
    }
}

final class Stack: Widget {
    init(transition: GtkStackTransitionType = GTK_STACK_TRANSITION_TYPE_CROSSFADE) {
        super.init(gtk_stack_new()!)
        gtk_stack_set_transition_type(widget.cast(), transition)
        gtk_stack_set_transition_duration(widget.cast(), 150)
    }

    @discardableResult
    func add(_ child: Widget, name: String) -> Self {
        gtk_stack_add_named(widget.cast(), child.widget, name)
        return self
    }

    var visibleName: String? {
        get { gtk_stack_get_visible_child_name(widget.cast()).map { String(cString: $0) } }
        set {
            guard let newValue else { return }
            gtk_stack_set_visible_child_name(widget.cast(), newValue)
        }
    }

    func child(named name: String) -> Widget? {
        gtk_stack_get_child_by_name(widget.cast(), name).map(Widget.init)
    }

    func remove(_ child: Widget) {
        gtk_stack_remove(widget.cast(), child.widget)
    }

    /// Size to the visible child only, so a short page does not take a long one's height.
    @discardableResult
    func interpolatesSize() -> Self {
        gtk_stack_set_hhomogeneous(widget.cast(), 0)
        gtk_stack_set_vhomogeneous(widget.cast(), 0)
        gtk_stack_set_interpolate_size(widget.cast(), 1)
        return self
    }
}

final class CenterBox: Widget {
    init(start: Widget? = nil, center: Widget? = nil, end: Widget? = nil) {
        super.init(gtk_center_box_new()!)
        if let start { gtk_center_box_set_start_widget(widget.cast(), start.widget) }
        if let center { gtk_center_box_set_center_widget(widget.cast(), center.widget) }
        if let end { gtk_center_box_set_end_widget(widget.cast(), end.widget) }
    }
}

final class Revealer: Widget {
    init(_ child: Widget, transition: GtkRevealerTransitionType = GTK_REVEALER_TRANSITION_TYPE_SLIDE_DOWN) {
        super.init(gtk_revealer_new()!)
        gtk_revealer_set_child(widget.cast(), child.widget)
        gtk_revealer_set_transition_type(widget.cast(), transition)
    }

    var isRevealed: Bool {
        get { gtk_revealer_get_reveal_child(widget.cast()) != 0 }
        set { gtk_revealer_set_reveal_child(widget.cast(), newValue ? 1 : 0) }
    }
}

/// Children laid out in rows that wrap: chips, tags, a grid of a few cards.
final class FlowBox: Widget {
    init(spacing: UInt32 = 8, @WidgetBuilder _ content: () -> [Widget] = { [] }) {
        super.init(gtk_flow_box_new()!)
        gtk_flow_box_set_selection_mode(widget.cast(), GTK_SELECTION_NONE)
        gtk_flow_box_set_column_spacing(widget.cast(), spacing)
        gtk_flow_box_set_row_spacing(widget.cast(), spacing)
        gtk_flow_box_set_homogeneous(widget.cast(), 0)
        for child in content() { append(child) }
    }

    @discardableResult
    func append(_ child: Widget) -> Self {
        gtk_flow_box_append(widget.cast(), child.widget)
        return self
    }

    @discardableResult
    func columns(min: UInt32, max: UInt32) -> Self {
        gtk_flow_box_set_min_children_per_line(widget.cast(), min)
        gtk_flow_box_set_max_children_per_line(widget.cast(), max)
        return self
    }

    @discardableResult
    func homogeneous(_ value: Bool = true) -> Self {
        gtk_flow_box_set_homogeneous(widget.cast(), value ? 1 : 0)
        return self
    }

    func removeAll() {
        while let child = gtk_widget_get_first_child(widget) {
            gtk_flow_box_remove(widget.cast(), child)
        }
    }

    /// The child `index` was activated: clicked, or Enter on it.
    @discardableResult
    func onActivate(_ action: @escaping @MainActor (Int) -> Void) -> Self {
        Signal.connect(widget, "child-activated", pointer: { child in
            guard let child else { return }
            action(Int(gtk_flow_box_child_get_index(child.cast())))
        })
        return self
    }
}

final class Grid: Widget {
    init(rowSpacing: UInt32 = 6, columnSpacing: UInt32 = 12) {
        super.init(gtk_grid_new()!)
        gtk_grid_set_row_spacing(widget.cast(), rowSpacing)
        gtk_grid_set_column_spacing(widget.cast(), columnSpacing)
    }

    @discardableResult
    func attach(_ child: Widget, column: Int32, row: Int32, width: Int32 = 1, height: Int32 = 1) -> Self {
        gtk_grid_attach(widget.cast(), child.widget, column, row, width, height)
        return self
    }
}

final class Separator: Widget {
    init(_ orientation: GtkOrientation = GTK_ORIENTATION_HORIZONTAL) {
        super.init(gtk_separator_new(orientation)!)
    }
}

/// A flexible gap, for pushing the rest of a row to its end.
final class Spacer: Widget {
    init(horizontal: Bool = true) {
        super.init(gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)!)
        if horizontal { hexpand() } else { vexpand() }
    }
}

// MARK: - Content

final class Label: Widget {
    init(_ text: String = "", _ classes: String...) {
        super.init(gtk_label_new(text)!)
        gtk_label_set_xalign(widget.cast(), 0)
        for name in classes { gtk_widget_add_css_class(widget, name) }
    }

    /// Pango markup; escape anything that came from the server with `Markup.escape`.
    convenience init(markup: String, _ classes: String...) {
        self.init("")
        gtk_label_set_markup(widget.cast(), markup)
        for name in classes { gtk_widget_add_css_class(widget, name) }
    }

    var text: String {
        get { String(cString: gtk_label_get_text(widget.cast())) }
        set {
            guard newValue != text else { return }
            gtk_label_set_text(widget.cast(), newValue)
        }
    }

    func setMarkup(_ markup: String) {
        gtk_label_set_markup(widget.cast(), markup)
    }

    @discardableResult
    func wrap(_ value: Bool = true) -> Self {
        gtk_label_set_wrap(widget.cast(), value ? 1 : 0)
        gtk_label_set_wrap_mode(widget.cast(), PANGO_WRAP_WORD_CHAR)
        return self
    }

    @discardableResult
    func ellipsize(_ mode: PangoEllipsizeMode = PANGO_ELLIPSIZE_END) -> Self {
        gtk_label_set_ellipsize(widget.cast(), mode)
        return self
    }

    @discardableResult
    func xalign(_ value: Float) -> Self {
        gtk_label_set_xalign(widget.cast(), value)
        return self
    }

    @discardableResult
    func lines(_ count: Int32) -> Self {
        gtk_label_set_lines(widget.cast(), count)
        gtk_label_set_ellipsize(widget.cast(), PANGO_ELLIPSIZE_END)
        gtk_label_set_wrap(widget.cast(), 1)
        return self
    }

    @discardableResult
    func selectable(_ value: Bool = true) -> Self {
        gtk_label_set_selectable(widget.cast(), value ? 1 : 0)
        return self
    }

    @discardableResult
    func justify(_ justification: GtkJustification) -> Self {
        gtk_label_set_justify(widget.cast(), justification)
        return self
    }

    @discardableResult
    func maxWidthChars(_ count: Int32) -> Self {
        gtk_label_set_max_width_chars(widget.cast(), count)
        return self
    }

    @discardableResult
    func widthChars(_ count: Int32) -> Self {
        gtk_label_set_width_chars(widget.cast(), count)
        return self
    }
}

enum Markup {
    static func escape(_ text: String) -> String {
        String(gOwned: g_markup_escape_text(text, -1)) ?? ""
    }
}

/// A themed icon, by freedesktop name.
final class Icon: Widget {
    init(_ name: String, size: Int32 = 16) {
        super.init(gtk_image_new_from_icon_name(name)!)
        gtk_image_set_pixel_size(widget.cast(), size)
    }

    var name: String = "" {
        didSet { gtk_image_set_from_icon_name(widget.cast(), name) }
    }

    @discardableResult
    func pixelSize(_ size: Int32) -> Self {
        gtk_image_set_pixel_size(widget.cast(), size)
        return self
    }
}

/// An image that scales: artwork.
final class Picture: Widget {
    init() {
        super.init(gtk_picture_new()!)
        gtk_picture_set_can_shrink(widget.cast(), 1)
        gtk_picture_set_content_fit(widget.cast(), GTK_CONTENT_FIT_COVER)
    }

    func set(_ texture: Texture?) {
        gtk_picture_set_paintable(widget.cast(), texture?.paintable)
    }

    @discardableResult
    func fit(_ fit: GtkContentFit) -> Self {
        gtk_picture_set_content_fit(widget.cast(), fit)
        return self
    }
}

final class Button: Widget {
    /// `label`, `icon`, or both: an icon beside the label.
    init(_ label: String? = nil, icon: String? = nil, _ classes: String..., action: (@MainActor () -> Void)? = nil) {
        super.init(gtk_button_new()!)
        setContent(label: label, icon: icon)
        for name in classes { gtk_widget_add_css_class(widget, name) }
        if let action { onClicked(action) }
    }

    /// A button around any content: a card, a row.
    init(child: Widget, _ classes: String..., action: (@MainActor () -> Void)? = nil) {
        super.init(gtk_button_new()!)
        gtk_button_set_child(widget.cast(), child.widget)
        for name in classes { gtk_widget_add_css_class(widget, name) }
        if let action { onClicked(action) }
    }

    func setContent(label: String?, icon: String?) {
        switch (label, icon) {
        case let (label?, icon?):
            let content = adw_button_content_new()!
            adw_button_content_set_label(content.cast(), label)
            adw_button_content_set_icon_name(content.cast(), icon)
            gtk_button_set_child(widget.cast(), content)
        case let (label?, nil):
            gtk_button_set_label(widget.cast(), label)
        case let (nil, icon?):
            gtk_button_set_icon_name(widget.cast(), icon)
        case (nil, nil):
            break
        }
    }

    var icon: String = "" {
        didSet { gtk_button_set_icon_name(widget.cast(), icon) }
    }

    var label: String = "" {
        didSet { gtk_button_set_label(widget.cast(), label) }
    }

    @discardableResult
    func onClicked(_ action: @escaping @MainActor () -> Void) -> Self {
        Signal.connect(widget, "clicked", action)
        return self
    }
}

final class ToggleButton: Widget {
    private var settingQuietly = false

    init(_ label: String? = nil, icon: String? = nil, _ classes: String..., toggled: (@MainActor (Bool) -> Void)? = nil) {
        super.init(gtk_toggle_button_new()!)
        if let label { gtk_button_set_label(widget.cast(), label) }
        if let icon { gtk_button_set_icon_name(widget.cast(), icon) }
        for name in classes { gtk_widget_add_css_class(widget, name) }
        if let toggled {
            let reference = WeakReference(self)
            Signal.connect(widget, "toggled") { [widget] in
                guard reference.value?.settingQuietly != true else { return }
                toggled(gtk_toggle_button_get_active(widget.cast()) != 0)
            }
            keep(self)
        }
    }

    /// Setting this does not call the handler.
    var isActive: Bool {
        get { gtk_toggle_button_get_active(widget.cast()) != 0 }
        set {
            guard newValue != isActive else { return }
            settingQuietly = true
            gtk_toggle_button_set_active(widget.cast(), newValue ? 1 : 0)
            settingQuietly = false
        }
    }

    /// Makes this one of a set where exactly one is active.
    func group(with other: ToggleButton) {
        gtk_toggle_button_set_group(widget.cast(), other.widget.cast())
    }
}

final class Switch: Widget {
    init(_ isOn: Bool = false, changed: @escaping @MainActor (Bool) -> Void) {
        super.init(gtk_switch_new()!)
        gtk_switch_set_active(widget.cast(), isOn ? 1 : 0)
        gtk_widget_set_valign(widget, GTK_ALIGN_CENTER)
        Signal.connect(widget, "notify::active", pointer: { [widget] _ in
            changed(gtk_switch_get_active(widget.cast()) != 0)
        })
    }
}

final class CheckButton: Widget {
    init(_ label: String? = nil, active: Bool = false, toggled: @escaping @MainActor (Bool) -> Void) {
        super.init(gtk_check_button_new_with_label(label)!)
        gtk_check_button_set_active(widget.cast(), active ? 1 : 0)
        Signal.connect(widget, "toggled") { [widget] in
            toggled(gtk_check_button_get_active(widget.cast()) != 0)
        }
    }

    var isActive: Bool {
        get { gtk_check_button_get_active(widget.cast()) != 0 }
        set { gtk_check_button_set_active(widget.cast(), newValue ? 1 : 0) }
    }
}

final class Scale: Widget {
    init(min: Double, max: Double, step: Double, value: Double, orientation: GtkOrientation = GTK_ORIENTATION_HORIZONTAL) {
        super.init(gtk_scale_new_with_range(orientation, min, max, step)!)
        gtk_scale_set_draw_value(widget.cast(), 0)
        gtk_range_set_value(widget.cast(), value)
    }

    var value: Double {
        get { gtk_range_get_value(widget.cast()) }
        set { gtk_range_set_value(widget.cast(), newValue) }
    }

    /// Changed by the person, not by `value` being set.
    @discardableResult
    func onUserChange(_ action: @escaping @MainActor (Double) -> Void) -> Self {
        Signal.connect(widget, "change-value", changeValue: { value in
            action(value)
            return false
        })
        return self
    }

    @discardableResult
    func onChange(_ action: @escaping @MainActor (Double) -> Void) -> Self {
        Signal.connect(widget, "value-changed") { [widget] in
            action(gtk_range_get_value(widget.cast()))
        }
        return self
    }

    @discardableResult
    func marks(_ values: [Double], position: GtkPositionType = GTK_POS_BOTTOM) -> Self {
        for value in values { gtk_scale_add_mark(widget.cast(), value, position, nil) }
        return self
    }

    @discardableResult
    func showsValue(digits: Int32, position: GtkPositionType = GTK_POS_RIGHT) -> Self {
        gtk_scale_set_draw_value(widget.cast(), 1)
        gtk_scale_set_digits(widget.cast(), digits)
        gtk_scale_set_value_pos(widget.cast(), position)
        return self
    }

    @discardableResult
    func inverted(_ value: Bool = true) -> Self {
        gtk_range_set_inverted(widget.cast(), value ? 1 : 0)
        return self
    }
}

final class Entry: Widget {
    init(placeholder: String? = nil, text: String = "") {
        super.init(gtk_entry_new()!)
        gtk_entry_set_placeholder_text(widget.cast(), placeholder)
        self.text = text
    }

    var text: String {
        get { String(cString: gtk_editable_get_text(widget.cast())) }
        set { gtk_editable_set_text(widget.cast(), newValue) }
    }

    @discardableResult
    func onChange(_ action: @escaping @MainActor (String) -> Void) -> Self {
        Signal.connect(widget, "changed") { [widget] in
            action(String(cString: gtk_editable_get_text(widget.cast())))
        }
        return self
    }

    @discardableResult
    func onActivate(_ action: @escaping @MainActor () -> Void) -> Self {
        Signal.connect(widget, "activate", action)
        return self
    }

    @discardableResult
    func password() -> Self {
        gtk_entry_set_visibility(widget.cast(), 0)
        gtk_entry_set_input_purpose(widget.cast(), GTK_INPUT_PURPOSE_PASSWORD)
        return self
    }
}

final class SearchEntry: Widget {
    init(placeholder: String? = nil) {
        super.init(gtk_search_entry_new()!)
        if let placeholder {
            gtk_search_entry_set_placeholder_text(widget.cast(), placeholder)
        }
    }

    var text: String {
        get { String(cString: gtk_editable_get_text(widget.cast())) }
        set { gtk_editable_set_text(widget.cast(), newValue) }
    }

    /// Debounced by GTK, as a search field should be.
    @discardableResult
    func onSearch(_ action: @escaping @MainActor (String) -> Void) -> Self {
        Signal.connect(widget, "search-changed") { [widget] in
            action(String(cString: gtk_editable_get_text(widget.cast())))
        }
        return self
    }

    @discardableResult
    func onActivate(_ action: @escaping @MainActor () -> Void) -> Self {
        Signal.connect(widget, "activate", action)
        return self
    }

    @discardableResult
    func searchDelay(_ milliseconds: UInt32) -> Self {
        gtk_search_entry_set_search_delay(widget.cast(), milliseconds)
        return self
    }
}

final class Spinner: Widget {
    init() {
        super.init(adw_spinner_new()!)
    }

    @discardableResult
    func size(_ side: Int32) -> Self {
        size(width: side, height: side)
    }
}

final class ProgressBar: Widget {
    init() {
        super.init(gtk_progress_bar_new()!)
    }

    var fraction: Double {
        get { gtk_progress_bar_get_fraction(widget.cast()) }
        set { gtk_progress_bar_set_fraction(widget.cast(), newValue) }
    }
}

final class LevelBar: Widget {
    init(min: Double = 0, max: Double = 1) {
        super.init(gtk_level_bar_new_for_interval(min, max)!)
    }

    var value: Double {
        get { gtk_level_bar_get_value(widget.cast()) }
        set { gtk_level_bar_set_value(widget.cast(), newValue) }
    }
}

/// A widget whose only child can be swapped: the slot a screen's content goes in once it
/// has loaded.
final class Bin: Widget {
    init(_ child: Widget? = nil) {
        super.init(adw_bin_new()!)
        if let child { self.child = child }
    }

    var child: Widget? {
        get { adw_bin_get_child(widget.cast()).map(Widget.init) }
        set { adw_bin_set_child(widget.cast(), newValue?.widget) }
    }
}

/// Holds content to a readable width in the middle of a wide window.
final class Clamp: Widget {
    init(_ child: Widget, maximum: Int32 = 900, threshold: Int32 = 600) {
        super.init(adw_clamp_new()!)
        adw_clamp_set_child(widget.cast(), child.widget)
        adw_clamp_set_maximum_size(widget.cast(), maximum)
        adw_clamp_set_tightening_threshold(widget.cast(), threshold)
    }
}
