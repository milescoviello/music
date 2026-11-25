import SwiftUI

/// Everything asked for from the app, newest first: under way, waiting for a copy to be
/// picked, in the library, or failed -- with retry and cancel.
struct RequestsView: View {
    @Environment(AppState.self) private var appState
    @State private var error: String?

    private var grab: GrabService { appState.grab }

    var body: some View {
        Group {
            if grab.requests.isEmpty {
                ContentUnavailableView {
                    Label("Nothing Asked For", systemImage: "arrow.down.circle")
                } description: {
                    Text(grab.isAvailable
                         ? "Songs and albums you get from Search, an artist's page or a song's menu show up here as they come in."
                         : "Getting music needs the server's request service, which isn't answering right now.")
                }
            } else {
                List {
                    ForEach(grab.requests) { request in
                        NavigationLink(value: Destination.grabRequest(request.id)) {
                            GrabRequestRow(request: request)
                        }
                        .swipeActions(edge: .trailing) {
                            if request.state.isActive || request.state == .choosing {
                                Button("Cancel", systemImage: "xmark", role: .destructive) {
                                    Task { await act { try await grab.cancel(request) } }
                                }
                            }
                            if request.state == .failed || request.state == .cancelled {
                                Button("Try Again", systemImage: "arrow.clockwise") {
                                    Task { await act { try await grab.retry(request) } }
                                }
                                .tint(Color.appTint)
                            }
                        }
                        .clearRow()
                    }
                }
                .listStyle(.plain)
                .refreshable { await grab.refresh() }
            }
        }
        .navigationTitle("Requests")
        .pageBackdrop()
        .alert("Couldn't Do That", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
        .task { await grab.refreshAvailability(force: true) }
        .onAppear { grab.beginWatchingClosely() }
        .onDisappear { grab.endWatchingClosely() }
    }

    private func act(_ work: () async throws -> Void) async {
        do {
            try await work()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
