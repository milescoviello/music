import SwiftUI

/// Says the app is offline, once, at the top of the screen.
///
/// The failure this replaces: every load used `try? await`, so with the server
/// unreachable the shelves and lists simply came back *empty* — no error, no
/// explanation, nothing to act on. An empty library looks like a broken app, and that
/// is a worse outcome than an honest message.
///
/// Only shown when there is actually something to say: offline *and* displaying saved
/// data, or offline with nothing saved at all.
struct OfflineBanner: View {
    @Environment(AppState.self) private var appState
    @Environment(Reachability.self) private var reachability
    @Environment(DownloadCenter.self) private var downloads

    var body: some View {
        if !reachability.isOnline || appState.isShowingCachedData {
            HStack(spacing: 8) {
                Image(systemName: "wifi.slash")
                    .font(.caption)

                Text(message)
                    .font(.caption)
                    .lineLimit(1)

                Spacer(minLength: 4)

                if downloads.catalog.entries.isEmpty == false {
                    NavigationLink(value: Destination.downloads) {
                        Text("Downloads")
                            .font(.caption.weight(.semibold))
                    }
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, Metrics.gutter)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(Color.appTint.opacity(0.85))
        }
    }

    private var message: String {
        // A network, and a server that did not answer: not "offline", which is what it
        // said, over results the server had just sent.
        if reachability.isOnline { return "The server isn’t answering — showing saved copies" }
        let count = downloads.catalog.entries.count
        if count > 0 {
            return "Offline — \(count) downloaded \(count == 1 ? "track" : "tracks") available"
        }
        return "Offline — nothing is downloaded yet"
    }
}

extension View {
    /// Attach inside a `NavigationStack`, so the banner's link has somewhere to push.
    func offlineBanner() -> some View {
        safeAreaInset(edge: .top, spacing: 0) { OfflineBanner() }
    }
}
