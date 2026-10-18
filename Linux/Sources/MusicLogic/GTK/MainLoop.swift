import CGtk
import Foundation

/// GLib's main loop, made to run Swift's main actor too.
///
/// On Linux the main actor is libdispatch's main queue, which nothing drains unless a
/// run loop asks it to — Foundation's `RunLoop` does, GTK's does not. libdispatch exposes
/// the queue's wake-up as a file descriptor for exactly this; watching it from GLib and
/// draining the queue when it fires puts every `Task { @MainActor in }`, every
/// `DispatchQueue.main.async` and every `await` that resumes on the main actor onto GTK's
/// thread, in GTK's loop.
@MainActor
enum MainLoop {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        let handle = _dispatch_get_main_queue_handle_4CF()
        let channel = g_io_channel_unix_new(handle)
        g_io_add_watch(channel, G_IO_IN, { channel, _, _ in
            // The handle is an eventfd. It must be read, or it stays readable and this
            // watch fires forever — a busy loop at default priority that starves GTK's
            // own drawing, so no window ever appears. Foundation's RunLoop reads it too.
            var count: UInt64 = 0
            _ = read(g_io_channel_unix_get_fd(channel), &count, MemoryLayout<UInt64>.size)
            _dispatch_main_queue_callback_4CF(nil)
            return 1
        }, nil)
        g_io_channel_unref(channel)
    }

    /// For running without a GTK application: tests, and the first build of the core.
    static func run() {
        let loop = g_main_loop_new(nil, 0)
        g_main_loop_run(loop)
    }
}
