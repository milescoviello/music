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
static inline GVariantType *cgtk_variant_type(const char *string) { return (GVariantType *)string; }
