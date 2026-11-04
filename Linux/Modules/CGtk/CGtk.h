#include <gtk/gtk.h>
#include <adwaita.h>
#include <gio/gio.h>
#include <glib-unix.h>

// libdispatch's hooks for a run loop that is not its own. Exported but undeclared: they
// are how Foundation's RunLoop drains the main queue, and how GLib's main loop does here.
// Without them nothing scheduled on the main actor would ever run under GTK.
int _dispatch_get_main_queue_handle_4CF(void);
void _dispatch_main_queue_callback_4CF(void *msg);

// Macros, and macros dressed as functions, that Swift cannot see.
static inline guint cgtk_invalid_list_position(void) { return GTK_INVALID_LIST_POSITION; }
static inline GType cgtk_string_object_type(void) { return GTK_TYPE_STRING_OBJECT; }
static inline guint cgtk_disconnect_by_data(gpointer instance, gpointer data) {
    return g_signal_handlers_disconnect_matched(instance, G_SIGNAL_MATCH_DATA, 0, 0, NULL, NULL, data);
}
static inline gboolean cgtk_is_widget(gpointer object) { return GTK_IS_WIDGET(object); }
// GVariant types from constant storage. The cast of a C string these replace was handed
// the copy Swift makes of a short `String` for the length of one call, gone before GLib
// read it: MPRIS's "s" and "{sv}" crashed the app now and then, on a track change, with
// "g_variant_type_info_get: assertion failed (0 <= -50)" (2026-11-04).
static inline const GVariantType *cgtk_type_string(void) { return G_VARIANT_TYPE_STRING; }
static inline const GVariantType *cgtk_type_byte(void) { return G_VARIANT_TYPE_BYTE; }
static inline const GVariantType *cgtk_type_bytestring(void) { return G_VARIANT_TYPE_BYTESTRING; }
static inline const GVariantType *cgtk_type_string_variant_entry(void) { return G_VARIANT_TYPE("{sv}"); }
