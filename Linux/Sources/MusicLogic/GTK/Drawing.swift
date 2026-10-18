import CGtk
import Foundation

/// A widget drawn by hand with cairo: the seekbar's loudness outline, the visualiser, the
/// charts. The draw closure runs whenever GTK repaints; `redraw()` asks for one.
final class DrawingArea: Widget {
    init(width: Int32 = -1, height: Int32 = -1, draw: @escaping @MainActor (Cairo, Double, Double) -> Void) {
        super.init(gtk_drawing_area_new()!)
        if width > 0 { gtk_drawing_area_set_content_width(widget.cast(), width) }
        if height > 0 { gtk_drawing_area_set_content_height(widget.cast(), height) }
        typealias Draw = @MainActor (Cairo, Double, Double) -> Void
        let box = Unmanaged.passRetained(ClosureBox<Draw>(draw)).toOpaque()
        gtk_drawing_area_set_draw_func(widget.cast(), { _, context, width, height, data in
            guard let context, let data else { return }
            let draw = Unmanaged<ClosureBox<Draw>>.fromOpaque(data).takeUnretainedValue().value
            nonisolated(unsafe) let pointer = context
            MainActor.assumeIsolated { draw(Cairo(pointer), Double(width), Double(height)) }
        }, box, { data in
            guard let data else { return }
            Unmanaged<AnyObject>.fromOpaque(data).release()
        })
    }

    func redraw() {
        gtk_widget_queue_draw(widget)
    }
}

/// The few cairo calls the app draws with, named for what they do.
struct Cairo {
    let context: OpaquePointer

    init(_ context: OpaquePointer) {
        self.context = context
    }

    func color(_ rgb: ArtworkStore.RGB, alpha: Double = 1) {
        cairo_set_source_rgba(context, rgb.red, rgb.green, rgb.blue, alpha)
    }

    func color(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        cairo_set_source_rgba(context, red, green, blue, alpha)
    }

    func rectangle(_ x: Double, _ y: Double, _ width: Double, _ height: Double) {
        cairo_rectangle(context, x, y, width, height)
    }

    func roundedRectangle(_ x: Double, _ y: Double, _ width: Double, _ height: Double, radius: Double) {
        let r = min(radius, width / 2, height / 2)
        cairo_new_sub_path(context)
        cairo_arc(context, x + width - r, y + r, r, -.pi / 2, 0)
        cairo_arc(context, x + width - r, y + height - r, r, 0, .pi / 2)
        cairo_arc(context, x + r, y + height - r, r, .pi / 2, .pi)
        cairo_arc(context, x + r, y + r, r, .pi, 3 * .pi / 2)
        cairo_close_path(context)
    }

    func move(_ x: Double, _ y: Double) { cairo_move_to(context, x, y) }
    func line(_ x: Double, _ y: Double) { cairo_line_to(context, x, y) }
    func curve(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ x: Double, _ y: Double) {
        cairo_curve_to(context, x1, y1, x2, y2, x, y)
    }
    func close() { cairo_close_path(context) }
    func fill() { cairo_fill(context) }
    func fillPreserve() { cairo_fill_preserve(context) }
    func stroke(width: Double) {
        cairo_set_line_width(context, width)
        cairo_stroke(context)
    }
    func save() { cairo_save(context) }
    func restore() { cairo_restore(context) }
    func clip() { cairo_clip(context) }
    func paint(alpha: Double = 1) { cairo_paint_with_alpha(context, alpha) }

    /// A vertical gradient from `top` to `bottom`, as the current source.
    func verticalGradient(height: Double, _ stops: [(Double, ArtworkStore.RGB, Double)]) {
        let pattern = cairo_pattern_create_linear(0, 0, 0, height)
        for (offset, rgb, alpha) in stops {
            cairo_pattern_add_color_stop_rgba(pattern, offset, rgb.red, rgb.green, rgb.blue, alpha)
        }
        cairo_set_source(context, pattern)
        cairo_pattern_destroy(pattern)
    }

    /// Text at a point, in the widget's font at `size` points.
    func text(_ string: String, x: Double, y: Double, size: Double, bold: Bool = false) {
        cairo_select_font_face(context, "Sans", CAIRO_FONT_SLANT_NORMAL, bold ? CAIRO_FONT_WEIGHT_BOLD : CAIRO_FONT_WEIGHT_NORMAL)
        cairo_set_font_size(context, size)
        cairo_move_to(context, x, y)
        cairo_show_text(context, string)
    }

    func textWidth(_ string: String, size: Double, bold: Bool = false) -> Double {
        cairo_select_font_face(context, "Sans", CAIRO_FONT_SLANT_NORMAL, bold ? CAIRO_FONT_WEIGHT_BOLD : CAIRO_FONT_WEIGHT_NORMAL)
        cairo_set_font_size(context, size)
        var extents = cairo_text_extents_t()
        cairo_text_extents(context, string, &extents)
        return extents.x_advance
    }
}

/// Calls `body` on every frame the widget is drawn, for animation: the visualiser. Stops
/// when the returned id is removed with `stopTicking`.
@MainActor
@discardableResult
func tick(_ widget: Widget, _ body: @escaping @MainActor () -> Bool) -> guint {
    typealias Tick = @MainActor () -> Bool
    let box = Unmanaged.passRetained(ClosureBox<Tick>(body)).toOpaque()
    return gtk_widget_add_tick_callback(widget.widget, { _, _, data in
        guard let data else { return 0 }
        let body = Unmanaged<ClosureBox<Tick>>.fromOpaque(data).takeUnretainedValue().value
        return MainActor.assumeIsolated { body() } ? 1 : 0
    }, box, { data in
        guard let data else { return }
        Unmanaged<AnyObject>.fromOpaque(data).release()
    })
}
