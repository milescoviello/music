import CGtk
import Foundation

// libadwaita's building blocks: the header bars, pages, preference rows and sheets that
// make a GTK app look like it belongs on the desktop it runs on.

final class HeaderBar: Widget {
    init() {
        super.init(adw_header_bar_new()!)
    }

    @discardableResult
    func start(_ child: Widget) -> Self {
        adw_header_bar_pack_start(widget.cast(), child.widget)
        return self
    }

    @discardableResult
    func end(_ child: Widget) -> Self {
        adw_header_bar_pack_end(widget.cast(), child.widget)
        return self
    }

    @discardableResult
    func title(_ child: Widget?) -> Self {
        adw_header_bar_set_title_widget(widget.cast(), child?.widget)
        return self
    }

    /// The page's title, shown by the header bar of the page it is in.
    @discardableResult
    func showsTitle(_ value: Bool) -> Self {
        adw_header_bar_set_show_title(widget.cast(), value ? 1 : 0)
        return self
    }

    @discardableResult
    func showsBackButton(_ value: Bool) -> Self {
        adw_header_bar_set_show_back_button(widget.cast(), value ? 1 : 0)
        return self
    }

    @discardableResult
    func showsEndControls(_ value: Bool) -> Self {
        adw_header_bar_set_show_end_title_buttons(widget.cast(), value ? 1 : 0)
        return self
    }

    @discardableResult
    func showsStartControls(_ value: Bool) -> Self {
        adw_header_bar_set_show_start_title_buttons(widget.cast(), value ? 1 : 0)
        return self
    }
}

/// A title and a subtitle, for a header bar's middle.
final class WindowTitle: Widget {
    init(_ title: String, subtitle: String = "") {
        super.init(adw_window_title_new(title, subtitle)!)
    }

    var title: String {
        get { String(cString: adw_window_title_get_title(widget.cast())) }
        set { adw_window_title_set_title(widget.cast(), newValue) }
    }

    var subtitle: String {
        get { String(cString: adw_window_title_get_subtitle(widget.cast())) }
        set { adw_window_title_set_subtitle(widget.cast(), newValue) }
    }
}

/// Bars above and below content, which the content scrolls under.
final class ToolbarView: Widget {
    init(content: Widget? = nil) {
        super.init(adw_toolbar_view_new()!)
        if let content { self.content = content }
    }

    var content: Widget? {
        get { adw_toolbar_view_get_content(widget.cast()).map(Widget.init) }
        set { adw_toolbar_view_set_content(widget.cast(), newValue?.widget) }
    }

    @discardableResult
    func top(_ bar: Widget) -> Self {
        adw_toolbar_view_add_top_bar(widget.cast(), bar.widget)
        return self
    }

    @discardableResult
    func bottom(_ bar: Widget) -> Self {
        adw_toolbar_view_add_bottom_bar(widget.cast(), bar.widget)
        return self
    }

    @discardableResult
    func topStyle(_ style: AdwToolbarStyle) -> Self {
        adw_toolbar_view_set_top_bar_style(widget.cast(), style)
        return self
    }

    @discardableResult
    func extendsContentToTop(_ value: Bool = true) -> Self {
        adw_toolbar_view_set_extend_content_to_top_edge(widget.cast(), value ? 1 : 0)
        return self
    }

    var revealsBottomBars: Bool {
        get { adw_toolbar_view_get_reveal_bottom_bars(widget.cast()) != 0 }
        set { adw_toolbar_view_set_reveal_bottom_bars(widget.cast(), newValue ? 1 : 0) }
    }
}

final class NavigationPage: Widget {
    init(_ child: Widget, title: String, tag: String? = nil) {
        super.init(adw_navigation_page_new(child.widget, title)!)
        if let tag { adw_navigation_page_set_tag(widget.cast(), tag) }
    }

    /// A handle on a page that already exists.
    init(existing pointer: GPointer) {
        super.init(pointer)
    }

    var title: String {
        get { String(cString: adw_navigation_page_get_title(widget.cast())) }
        set { adw_navigation_page_set_title(widget.cast(), newValue) }
    }

    /// Each time the page becomes the visible one: pushed, or popped back to.
    @discardableResult
    func onShown(_ action: @escaping @MainActor () -> Void) -> Self {
        Signal.connect(widget, "shown", action)
        return self
    }

    @discardableResult
    func onHidden(_ action: @escaping @MainActor () -> Void) -> Self {
        Signal.connect(widget, "hidden", action)
        return self
    }
}

final class NavigationView: Widget {
    init() {
        super.init(adw_navigation_view_new()!)
    }

    func push(_ page: NavigationPage) {
        adw_navigation_view_push(widget.cast(), page.widget.cast())
    }

    @discardableResult
    func pop() -> Bool {
        adw_navigation_view_pop(widget.cast()) != 0
    }

    /// Back to the first page.
    func popToRoot() {
        guard let stack = adw_navigation_view_get_navigation_stack(widget.cast()) else { return }
        defer { g_object_unref(stack.rawPointer) }
        guard g_list_model_get_n_items(stack) > 1,
              let first = g_list_model_get_item(stack, 0)
        else { return }
        defer { g_object_unref(first) }
        adw_navigation_view_pop_to_page(widget.cast(), first.assumingMemoryBound(to: AdwNavigationPage.self))
    }

    /// Replaces the whole stack with one page.
    func replace(with page: NavigationPage) {
        var pages: [OpaquePointer?] = [OpaquePointer(page.widget)]
        pages.withUnsafeMutableBufferPointer { buffer in
            adw_navigation_view_replace(widget.cast(), buffer.baseAddress?.withMemoryRebound(to: UnsafeMutablePointer<AdwNavigationPage>?.self, capacity: 1) { $0 }, 1)
        }
    }

    var depth: Int {
        guard let stack = adw_navigation_view_get_navigation_stack(widget.cast()) else { return 0 }
        defer { g_object_unref(stack.rawPointer) }
        return Int(g_list_model_get_n_items(stack))
    }

    var visiblePage: NavigationPage? {
        adw_navigation_view_get_visible_page(widget.cast()).map { NavigationPage(existing: $0) }
    }
}


final class NavigationSplitView: Widget {
    init(sidebar: NavigationPage, content: NavigationPage) {
        super.init(adw_navigation_split_view_new()!)
        adw_navigation_split_view_set_sidebar(widget.cast(), sidebar.widget.cast())
        adw_navigation_split_view_set_content(widget.cast(), content.widget.cast())
    }

    var isCollapsed: Bool {
        get { adw_navigation_split_view_get_collapsed(widget.cast()) != 0 }
        set { adw_navigation_split_view_set_collapsed(widget.cast(), newValue ? 1 : 0) }
    }

    var showsContent: Bool {
        get { adw_navigation_split_view_get_show_content(widget.cast()) != 0 }
        set { adw_navigation_split_view_set_show_content(widget.cast(), newValue ? 1 : 0) }
    }

    @discardableResult
    func sidebarWidth(min: Double, max: Double, fraction: Double) -> Self {
        adw_navigation_split_view_set_min_sidebar_width(widget.cast(), min)
        adw_navigation_split_view_set_max_sidebar_width(widget.cast(), max)
        adw_navigation_split_view_set_sidebar_width_fraction(widget.cast(), fraction)
        return self
    }
}

/// A sheet that slides up over the window, with a bar showing while it is closed: the
/// mini player and the full one.
final class BottomSheet: Widget {
    init(content: Widget, sheet: Widget, bar: Widget) {
        super.init(adw_bottom_sheet_new()!)
        adw_bottom_sheet_set_content(widget.cast(), content.widget)
        adw_bottom_sheet_set_sheet(widget.cast(), sheet.widget)
        adw_bottom_sheet_set_bottom_bar(widget.cast(), bar.widget)
        adw_bottom_sheet_set_full_width(widget.cast(), 1)
        adw_bottom_sheet_set_show_drag_handle(widget.cast(), 1)
    }

    var isOpen: Bool {
        get { adw_bottom_sheet_get_open(widget.cast()) != 0 }
        set {
            guard newValue != isOpen else { return }
            adw_bottom_sheet_set_open(widget.cast(), newValue ? 1 : 0)
        }
    }

    var revealsBar: Bool {
        get { adw_bottom_sheet_get_reveal_bottom_bar(widget.cast()) != 0 }
        set { adw_bottom_sheet_set_reveal_bottom_bar(widget.cast(), newValue ? 1 : 0) }
    }

    var canOpen: Bool {
        get { adw_bottom_sheet_get_can_open(widget.cast()) != 0 }
        set { adw_bottom_sheet_set_can_open(widget.cast(), newValue ? 1 : 0) }
    }

    @discardableResult
    func onOpenChanged(_ action: @escaping @MainActor (Bool) -> Void) -> Self {
        Signal.connect(widget, "notify::open", pointer: { [widget] _ in
            action(adw_bottom_sheet_get_open(widget.cast()) != 0)
        })
        return self
    }
}

final class StatusPage: Widget {
    init(icon: String? = nil, title: String, description: String? = nil, child: Widget? = nil) {
        super.init(adw_status_page_new()!)
        if let icon { adw_status_page_set_icon_name(widget.cast(), icon) }
        adw_status_page_set_title(widget.cast(), title)
        if let description { adw_status_page_set_description(widget.cast(), description) }
        if let child { adw_status_page_set_child(widget.cast(), child.widget) }
    }

    var title: String {
        get { String(cString: adw_status_page_get_title(widget.cast())) }
        set { adw_status_page_set_title(widget.cast(), newValue) }
    }

    var descriptionText: String {
        get { adw_status_page_get_description(widget.cast()).map { String(cString: $0) } ?? "" }
        set { adw_status_page_set_description(widget.cast(), newValue) }
    }

    @discardableResult
    func compact() -> Self {
        css("compact")
    }
}

final class Banner: Widget {
    init(_ title: String = "", button: String? = nil, action: (@MainActor () -> Void)? = nil) {
        super.init(adw_banner_new(title)!)
        if let button { adw_banner_set_button_label(widget.cast(), button) }
        if let action { Signal.connect(widget, "button-clicked", action) }
    }

    var title: String {
        get { String(cString: adw_banner_get_title(widget.cast())) }
        set { adw_banner_set_title(widget.cast(), newValue) }
    }

    var isRevealed: Bool {
        get { adw_banner_get_revealed(widget.cast()) != 0 }
        set { adw_banner_set_revealed(widget.cast(), newValue ? 1 : 0) }
    }
}

final class ToastOverlay: Widget {
    init(_ child: Widget) {
        super.init(adw_toast_overlay_new()!)
        adw_toast_overlay_set_child(widget.cast(), child.widget)
    }

    func show(_ title: String, timeout: UInt32 = 2, button: String? = nil, action: (@MainActor () -> Void)? = nil) {
        let toast = adw_toast_new(title)!
        adw_toast_set_timeout(toast, timeout)
        if let button, let action {
            adw_toast_set_button_label(toast, button)
            Signal.connect(toast, "button-clicked", action)
        }
        adw_toast_overlay_add_toast(widget.cast(), toast)
    }
}

final class Avatar: Widget {
    init(size: Int32, text: String?) {
        super.init(adw_avatar_new(size, text, 1)!)
    }

    func set(_ texture: Texture?) {
        adw_avatar_set_custom_image(widget.cast(), texture?.paintable)
    }
}

// MARK: - Preferences

final class PreferencesPage: Widget {
    init(title: String = "", icon: String? = nil, @WidgetBuilder _ groups: () -> [Widget] = { [] }) {
        super.init(adw_preferences_page_new()!)
        adw_preferences_page_set_title(widget.cast(), title)
        if let icon { adw_preferences_page_set_icon_name(widget.cast(), icon) }
        for group in groups() { add(group) }
    }

    @discardableResult
    func add(_ group: Widget) -> Self {
        adw_preferences_page_add(widget.cast(), group.widget.cast())
        return self
    }

    func remove(_ group: Widget) {
        adw_preferences_page_remove(widget.cast(), group.widget.cast())
    }
}

final class PreferencesGroup: Widget {
    init(_ title: String = "", description: String? = nil, @WidgetBuilder _ rows: () -> [Widget] = { [] }) {
        super.init(adw_preferences_group_new()!)
        if !title.isEmpty { adw_preferences_group_set_title(widget.cast(), Markup.escape(title)) }
        if let description { adw_preferences_group_set_description(widget.cast(), Markup.escape(description)) }
        for row in rows() { add(row) }
    }

    @discardableResult
    func add(_ row: Widget) -> Self {
        adw_preferences_group_add(widget.cast(), row.widget)
        return self
    }

    func remove(_ row: Widget) {
        adw_preferences_group_remove(widget.cast(), row.widget)
    }

    /// A widget beside the title: an Edit button, a count.
    @discardableResult
    func suffix(_ child: Widget) -> Self {
        adw_preferences_group_set_header_suffix(widget.cast(), child.widget)
        return self
    }

    var descriptionText: String {
        get { adw_preferences_group_get_description(widget.cast()).map { String(cString: $0) } ?? "" }
        set { adw_preferences_group_set_description(widget.cast(), Markup.escape(newValue)) }
    }
}

/// A list row with a title, a subtitle, and widgets either side.
final class ActionRow: Widget {
    init(_ title: String, subtitle: String? = nil, icon: String? = nil, action: (@MainActor () -> Void)? = nil) {
        super.init(adw_action_row_new()!)
        self.title = title
        if let subtitle { self.subtitle = subtitle }
        if let icon { adw_action_row_add_prefix(widget.cast(), Icon(icon).widget) }
        if let action { activated(action) }
    }

    var title: String {
        get { String(cString: adw_preferences_row_get_title(widget.cast())) }
        set {
            adw_preferences_row_set_use_markup(widget.cast(), 0)
            adw_preferences_row_set_title(widget.cast(), newValue)
        }
    }

    var subtitle: String {
        get { adw_action_row_get_subtitle(widget.cast()).map { String(cString: $0) } ?? "" }
        set { adw_action_row_set_subtitle(widget.cast(), newValue) }
    }

    @discardableResult
    func prefix(_ child: Widget) -> Self {
        adw_action_row_add_prefix(widget.cast(), child.widget)
        return self
    }

    @discardableResult
    func suffix(_ child: Widget) -> Self {
        adw_action_row_add_suffix(widget.cast(), child.widget)
        return self
    }

    /// A chevron, for a row that opens another page.
    @discardableResult
    func chevron() -> Self {
        suffix(Icon("go-next-symbolic"))
    }

    @discardableResult
    func activated(_ action: @escaping @MainActor () -> Void) -> Self {
        gtk_list_box_row_set_activatable(widget.cast(), 1)
        Signal.connect(widget, "activated", action)
        return self
    }

    @discardableResult
    func subtitleLines(_ count: Int32) -> Self {
        adw_action_row_set_subtitle_lines(widget.cast(), count)
        return self
    }

    @discardableResult
    func titleLines(_ count: Int32) -> Self {
        adw_action_row_set_title_lines(widget.cast(), count)
        return self
    }

    @discardableResult
    func subtitleSelectable() -> Self {
        adw_action_row_set_subtitle_selectable(widget.cast(), 1)
        return self
    }
}

final class SwitchRow: Widget {
    init(_ title: String, subtitle: String? = nil, isOn: Bool, changed: @escaping @MainActor (Bool) -> Void) {
        super.init(adw_switch_row_new()!)
        adw_preferences_row_set_title(widget.cast(), title)
        if let subtitle { adw_action_row_set_subtitle(widget.cast(), subtitle) }
        adw_switch_row_set_active(widget.cast(), isOn ? 1 : 0)
        Signal.connect(widget, "notify::active", pointer: { [widget] _ in
            changed(adw_switch_row_get_active(widget.cast()) != 0)
        })
    }

    /// Setting this calls the handler too, so only set it from state that differs.
    var isOn: Bool {
        get { adw_switch_row_get_active(widget.cast()) != 0 }
        set {
            guard newValue != isOn else { return }
            adw_switch_row_set_active(widget.cast(), newValue ? 1 : 0)
        }
    }
}

/// A row that picks one of a few strings.
final class ComboRow: Widget {
    init(_ title: String, subtitle: String? = nil, options: [String], selected: Int, changed: @escaping @MainActor (Int) -> Void) {
        super.init(adw_combo_row_new()!)
        adw_preferences_row_set_title(widget.cast(), title)
        if let subtitle { adw_action_row_set_subtitle(widget.cast(), subtitle) }
        setOptions(options, selected: selected)
        Signal.connect(widget, "notify::selected", pointer: { [widget] _ in
            changed(Int(adw_combo_row_get_selected(widget.cast())))
        })
    }

    func setOptions(_ options: [String], selected: Int) {
        let list = gtk_string_list_new(nil)!
        for option in options { gtk_string_list_append(list, option) }
        adw_combo_row_set_model(widget.cast(), list)
        g_object_unref(list.rawPointer)
        adw_combo_row_set_selected(widget.cast(), guint(max(0, selected)))
    }

    var selected: Int {
        get { Int(adw_combo_row_get_selected(widget.cast())) }
        set {
            guard newValue != selected else { return }
            adw_combo_row_set_selected(widget.cast(), guint(max(0, newValue)))
        }
    }
}

final class EntryRow: Widget {
    init(_ title: String, text: String = "", password: Bool = false) {
        super.init(password ? adw_password_entry_row_new()! : adw_entry_row_new()!)
        adw_preferences_row_set_title(widget.cast(), title)
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

    /// An Apply button appears once the text changes, and Enter applies too.
    @discardableResult
    func onApply(_ action: @escaping @MainActor (String) -> Void) -> Self {
        adw_entry_row_set_show_apply_button(widget.cast(), 1)
        Signal.connect(widget, "apply") { [widget] in
            action(String(cString: gtk_editable_get_text(widget.cast())))
        }
        Signal.connect(widget, "entry-activated") { [widget] in
            action(String(cString: gtk_editable_get_text(widget.cast())))
        }
        return self
    }

    @discardableResult
    func inputPurpose(_ purpose: GtkInputPurpose) -> Self {
        adw_entry_row_set_input_purpose(widget.cast(), purpose)
        return self
    }
}

final class SpinRow: Widget {
    init(_ title: String, subtitle: String? = nil, min: Double, max: Double, step: Double, value: Double, digits: UInt32 = 0, changed: @escaping @MainActor (Double) -> Void) {
        super.init(adw_spin_row_new_with_range(min, max, step)!)
        adw_preferences_row_set_title(widget.cast(), title)
        if let subtitle { adw_action_row_set_subtitle(widget.cast(), subtitle) }
        adw_spin_row_set_digits(widget.cast(), digits)
        adw_spin_row_set_value(widget.cast(), value)
        Signal.connect(widget, "notify::value", pointer: { [widget] _ in
            changed(adw_spin_row_get_value(widget.cast()))
        })
    }
}

final class ExpanderRow: Widget {
    init(_ title: String, subtitle: String? = nil, @WidgetBuilder _ rows: () -> [Widget] = { [] }) {
        super.init(adw_expander_row_new()!)
        adw_preferences_row_set_title(widget.cast(), title)
        if let subtitle { adw_expander_row_set_subtitle(widget.cast(), subtitle) }
        for row in rows() { add(row) }
    }

    @discardableResult
    func add(_ row: Widget) -> Self {
        adw_expander_row_add_row(widget.cast(), row.widget)
        return self
    }

    @discardableResult
    func suffix(_ child: Widget) -> Self {
        adw_expander_row_add_suffix(widget.cast(), child.widget)
        return self
    }

    var isExpanded: Bool {
        get { adw_expander_row_get_expanded(widget.cast()) != 0 }
        set { adw_expander_row_set_expanded(widget.cast(), newValue ? 1 : 0) }
    }
}

/// A row that is a button: Sign Out, Clear.
final class ButtonRow: Widget {
    init(_ title: String, icon: String? = nil, destructive: Bool = false, suggested: Bool = false, action: @escaping @MainActor () -> Void) {
        super.init(adw_button_row_new()!)
        adw_preferences_row_set_title(widget.cast(), title)
        if let icon { adw_button_row_set_start_icon_name(widget.cast(), icon) }
        if destructive { css("destructive-action") }
        if suggested { css("suggested-action") }
        Signal.connect(widget, "activated", action)
    }
}

// MARK: - Dialogs

enum Dialogs {
    /// A question with buttons. `responses` are (id, label, style); the chosen id comes
    /// back, and "cancel" is what Escape chooses.
    @MainActor
    static func alert(
        _ heading: String,
        body: String? = nil,
        responses: [(String, String, AdwResponseAppearance)],
        defaultResponse: String? = nil,
        extra: Widget? = nil,
        over parent: Widget? = nil,
        chosen: @escaping @MainActor (String) -> Void
    ) {
        let dialog = adw_alert_dialog_new(heading, body)!
        for (id, label, appearance) in responses {
            adw_alert_dialog_add_response(dialog.cast(), id, label)
            adw_alert_dialog_set_response_appearance(dialog.cast(), id, appearance)
        }
        adw_alert_dialog_set_close_response(dialog.cast(), "cancel")
        if let defaultResponse { adw_alert_dialog_set_default_response(dialog.cast(), defaultResponse) }
        if let extra { adw_alert_dialog_set_extra_child(dialog.cast(), extra.widget) }
        Signal.connect(dialog, "response", pointer: { response in
            guard let response else { return }
            chosen(String(cString: response.assumingMemoryBound(to: CChar.self)))
        })
        adw_dialog_present(dialog.cast(), (parent?.widget ?? Desktop.window))
    }

    /// Asks for a line of text: a playlist's new name. Enter confirms.
    @MainActor
    static func prompt(
        _ heading: String,
        body: String? = nil,
        placeholder: String = "",
        text: String = "",
        confirm: String,
        over parent: Widget? = nil,
        entered: @escaping @MainActor (String) -> Void
    ) {
        let entry = Entry(placeholder: placeholder, text: text)
        gtk_entry_set_activates_default(entry.widget.cast(), 1)
        alert(
            heading, body: body,
            responses: [("cancel", "Cancel", ADW_RESPONSE_DEFAULT), ("ok", confirm, ADW_RESPONSE_SUGGESTED)],
            defaultResponse: "ok",
            extra: entry, over: parent
        ) { response in
            guard response == "ok" else { return }
            let value = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { entered(value) }
        }
        entry.grabFocus()
    }

    /// A page of its own in a floating dialog, closed by its header bar or Escape.
    @MainActor
    @discardableResult
    static func sheet(_ title: String, content: Widget, width: Int32 = 480, height: Int32 = 600, over parent: Widget? = nil) -> OpaquePointer {
        let dialog = adw_dialog_new()!
        adw_dialog_set_title(dialog.cast(), title)
        adw_dialog_set_content_width(dialog.cast(), width)
        adw_dialog_set_content_height(dialog.cast(), height)
        let toolbar = ToolbarView(content: content).top(HeaderBar())
        adw_dialog_set_child(dialog.cast(), toolbar.widget)
        adw_dialog_present(dialog.cast(), parent?.widget ?? Desktop.window)
        return OpaquePointer(dialog)
    }

    @MainActor
    static func close(_ dialog: OpaquePointer) {
        adw_dialog_close(dialog.cast())
    }
}
