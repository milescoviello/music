import CGtk
import Foundation

// The few things every GObject call from Swift needs: a way to pass one pointer type where
// C wants another, a way to hang Swift closures off signals, and a way to tie a Swift
// object's lifetime to a widget's.
//
// GLib's casting macros (`GTK_WIDGET(x)` and friends) are invisible to Swift and are only
// pointer casts once type-checking is compiled out, so `cast()` is the whole of them.

protocol GPointer {
    var rawPointer: UnsafeMutableRawPointer { get }
}

extension UnsafeMutablePointer: GPointer {
    var rawPointer: UnsafeMutableRawPointer { UnsafeMutableRawPointer(self) }
}

extension OpaquePointer: GPointer {
    var rawPointer: UnsafeMutableRawPointer { UnsafeMutableRawPointer(self) }
}

extension UnsafeMutableRawPointer: GPointer {
    var rawPointer: UnsafeMutableRawPointer { self }
}

extension GPointer {
    /// The same object, typed as whatever the C function being called wants.
    @inline(__always)
    func cast<T>() -> UnsafeMutablePointer<T> {
        rawPointer.assumingMemoryBound(to: T.self)
    }

    /// The same, for the C functions that take a final type, which Swift sees as opaque.
    @inline(__always)
    func cast() -> OpaquePointer {
        OpaquePointer(rawPointer)
    }

    @inline(__always)
    var opaque: OpaquePointer { OpaquePointer(rawPointer) }

    var gobject: UnsafeMutablePointer<GObject> { cast() }
}

/// Holds a Swift value for C. Released by `releaseBox`, which every connect passes as the
/// handler's destroy-notify, so a handler's closure lives exactly as long as the handler.
final class ClosureBox<Value> {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

private let releaseBox: GClosureNotify = { data, _ in
    guard let data else { return }
    Unmanaged<AnyObject>.fromOpaque(data).release()
}

@inline(__always)
private func unbox<Value>(_ data: UnsafeMutableRawPointer?, as _: Value.Type) -> Value {
    Unmanaged<ClosureBox<Value>>.fromOpaque(data!).takeUnretainedValue().value
}

/// Connecting Swift closures to GObject signals.
///
/// One trampoline per C signature, since a `@convention(c)` function cannot be generic or
/// capture anything. Signals are emitted on the main thread — GTK has no other — which is
/// what makes `assumeIsolated` true rather than hopeful.
@MainActor
enum Signal {
    typealias Handler = @MainActor () -> Void

    @discardableResult
    static func connect(_ instance: GPointer, _ name: String, _ handler: @escaping Handler) -> gulong {
        let trampoline: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { _, data in
            let handler = unbox(data, as: Handler.self)
            MainActor.assumeIsolated { handler() }
        }
        return attach(instance, name, unsafeBitCast(trampoline, to: GCallback.self), ClosureBox(handler))
    }

    /// For signals whose first argument is a pointer: `row-activated`, a factory's
    /// `setup` and `bind`, `notify`.
    @discardableResult
    static func connect(
        _ instance: GPointer,
        _ name: String,
        pointer handler: @escaping @MainActor (UnsafeMutableRawPointer?) -> Void
    ) -> gulong {
        typealias H = @MainActor (UnsafeMutableRawPointer?) -> Void
        let trampoline: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { _, argument, data in
            let handler = unbox(data, as: H.self)
            nonisolated(unsafe) let argument = argument
            MainActor.assumeIsolated { handler(argument) }
        }
        return attach(instance, name, unsafeBitCast(trampoline, to: GCallback.self), ClosureBox(handler))
    }

    /// For signals with one unsigned argument: a list view's `activate(position)`.
    @discardableResult
    static func connect(_ instance: GPointer, _ name: String, uint handler: @escaping @MainActor (UInt32) -> Void) -> gulong {
        typealias H = @MainActor (UInt32) -> Void
        let trampoline: @convention(c) (UnsafeMutableRawPointer?, guint, UnsafeMutableRawPointer?) -> Void = { _, value, data in
            let handler = unbox(data, as: H.self)
            MainActor.assumeIsolated { handler(value) }
        }
        return attach(instance, name, unsafeBitCast(trampoline, to: GCallback.self), ClosureBox(handler))
    }

    /// For signals with one boolean argument: GNetworkMonitor's `network-changed`.
    @discardableResult
    static func connect(_ instance: GPointer, _ name: String, bool handler: @escaping @MainActor (Bool) -> Void) -> gulong {
        typealias H = @MainActor (Bool) -> Void
        let trampoline: @convention(c) (UnsafeMutableRawPointer?, gboolean, UnsafeMutableRawPointer?) -> Void = { _, value, data in
            let handler = unbox(data, as: H.self)
            MainActor.assumeIsolated { handler(value != 0) }
        }
        return attach(instance, name, unsafeBitCast(trampoline, to: GCallback.self), ClosureBox(handler))
    }

    /// For signals that return whether they were handled: `close-request`. Its own name,
    /// so a trailing closure is never ambiguous with the plain `connect`.
    @discardableResult
    static func connectHandled(_ instance: GPointer, _ name: String, _ handler: @escaping @MainActor () -> Bool) -> gulong {
        typealias H = @MainActor () -> Bool
        let trampoline: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> gboolean = { _, data in
            let handler = unbox(data, as: H.self)
            return MainActor.assumeIsolated { handler() } ? 1 : 0
        }
        return attach(instance, name, unsafeBitCast(trampoline, to: GCallback.self), ClosureBox(handler))
    }

    /// A click gesture's `pressed` and `released`: presses, x, y.
    @discardableResult
    static func connect(
        _ instance: GPointer,
        _ name: String,
        press handler: @escaping @MainActor (Int32, Double, Double) -> Void
    ) -> gulong {
        typealias H = @MainActor (Int32, Double, Double) -> Void
        let trampoline: @convention(c) (UnsafeMutableRawPointer?, gint, gdouble, gdouble, UnsafeMutableRawPointer?) -> Void = { _, count, x, y, data in
            let handler = unbox(data, as: H.self)
            MainActor.assumeIsolated { handler(count, x, y) }
        }
        return attach(instance, name, unsafeBitCast(trampoline, to: GCallback.self), ClosureBox(handler))
    }

    /// Two doubles: a long press's `pressed`, a drag's `drag-begin`, `drag-update` and
    /// `drag-end`, a motion controller's `motion`.
    @discardableResult
    static func connect(
        _ instance: GPointer,
        _ name: String,
        point handler: @escaping @MainActor (Double, Double) -> Void
    ) -> gulong {
        typealias H = @MainActor (Double, Double) -> Void
        let trampoline: @convention(c) (UnsafeMutableRawPointer?, gdouble, gdouble, UnsafeMutableRawPointer?) -> Void = { _, x, y, data in
            let handler = unbox(data, as: H.self)
            MainActor.assumeIsolated { handler(x, y) }
        }
        return attach(instance, name, unsafeBitCast(trampoline, to: GCallback.self), ClosureBox(handler))
    }

    /// Two doubles, returning whether handled: a scroll controller's `scroll`.
    @discardableResult
    static func connect(
        _ instance: GPointer,
        _ name: String,
        scroll handler: @escaping @MainActor (Double, Double) -> Bool
    ) -> gulong {
        typealias H = @MainActor (Double, Double) -> Bool
        let trampoline: @convention(c) (UnsafeMutableRawPointer?, gdouble, gdouble, UnsafeMutableRawPointer?) -> gboolean = { _, x, y, data in
            let handler = unbox(data, as: H.self)
            return MainActor.assumeIsolated { handler(x, y) } ? 1 : 0
        }
        return attach(instance, name, unsafeBitCast(trampoline, to: GCallback.self), ClosureBox(handler))
    }

    /// A key controller's `key-pressed`: keyval, keycode, modifiers; true if handled.
    @discardableResult
    static func connect(
        _ instance: GPointer,
        _ name: String,
        key handler: @escaping @MainActor (UInt32, UInt32, GdkModifierType) -> Bool
    ) -> gulong {
        typealias H = @MainActor (UInt32, UInt32, GdkModifierType) -> Bool
        let trampoline: @convention(c) (UnsafeMutableRawPointer?, guint, guint, GdkModifierType, UnsafeMutableRawPointer?) -> gboolean = { _, keyval, keycode, state, data in
            let handler = unbox(data, as: H.self)
            return MainActor.assumeIsolated { handler(keyval, keycode, state) } ? 1 : 0
        }
        return attach(instance, name, unsafeBitCast(trampoline, to: GCallback.self), ClosureBox(handler))
    }

    /// GtkRange's `change-value`: scroll type, new value; true if handled.
    @discardableResult
    static func connect(
        _ instance: GPointer,
        _ name: String,
        changeValue handler: @escaping @MainActor (Double) -> Bool
    ) -> gulong {
        typealias H = @MainActor (Double) -> Bool
        let trampoline: @convention(c) (UnsafeMutableRawPointer?, GtkScrollType, gdouble, UnsafeMutableRawPointer?) -> gboolean = { _, _, value, data in
            let handler = unbox(data, as: H.self)
            return MainActor.assumeIsolated { handler(value) } ? 1 : 0
        }
        return attach(instance, name, unsafeBitCast(trampoline, to: GCallback.self), ClosureBox(handler))
    }

    static func disconnect(_ instance: GPointer, _ id: gulong) {
        g_signal_handler_disconnect(instance.gobject, id)
    }

    private static func attach(_ instance: GPointer, _ name: String, _ callback: GCallback, _ box: AnyObject) -> gulong {
        g_signal_connect_data(
            instance.gobject,
            name,
            callback,
            Unmanaged.passRetained(box).toOpaque(),
            releaseBox,
            GConnectFlags(rawValue: 0)
        )
    }
}

/// Ties a Swift object's lifetime to a GObject's: it is released when the object is
/// finalized. This is how a screen's controller lives exactly as long as its widgets, and
/// why controllers hold their widgets without owning them.
@MainActor
func retain(_ object: AnyObject, on owner: GPointer) {
    keepCounter += 1
    let destroy: GDestroyNotify = { data in
        guard let data else { return }
        Unmanaged<AnyObject>.fromOpaque(data).release()
    }
    g_object_set_data_full(owner.gobject, "swift-\(keepCounter)", Unmanaged.passRetained(object).toOpaque(), destroy)
}

@MainActor private var keepCounter = 0

/// A weak reference to a GObject, for async work that may finish after its widget has
/// gone: an artwork fetch, a server round trip.
final class WeakObject: @unchecked Sendable {
    private var reference = GWeakRef()

    init(_ object: GPointer) {
        g_weak_ref_init(&reference, object.rawPointer)
    }

    deinit {
        g_weak_ref_clear(&reference)
    }

    /// The object, with a strong reference the caller must balance with `g_object_unref`,
    /// or nil once it has been finalized. `withObject` is the safe form.
    func withObject<T>(_ body: (UnsafeMutableRawPointer) -> T) -> T? {
        guard let object = g_weak_ref_get(&reference) else { return nil }
        defer { g_object_unref(object) }
        return body(object)
    }
}

/// Carries a value the compiler cannot prove is `Sendable` across a boundary it is in fact
/// safe to cross: a GLib pointer handed from a callback to the main actor on the same
/// thread.
struct Unchecked<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

extension String {
    /// A C string GLib allocated, adopted and freed.
    init?(gOwned pointer: UnsafeMutablePointer<gchar>?) {
        guard let pointer else { return nil }
        self = String(cString: pointer)
        g_free(pointer)
    }
}
