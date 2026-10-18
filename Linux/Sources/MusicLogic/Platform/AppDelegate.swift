/// The phone's hand-off for downloads that finished while the app was not running. A
/// desktop process is not relaunched for that — a download runs while the app is open and
/// is retried on the next launch otherwise — so there is never a handler to call.
@MainActor
enum BackgroundSessionBridge {
    static func finish() {}
}
