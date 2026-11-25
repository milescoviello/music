import SwiftUI

/// Everything asked for from the app, newest first: under way, waiting for a copy to be
/// picked, in the library, or failed -- with retry and cancel. Above them, Soulseek at a
/// glance, which opens the monitor (`SoulseekMonitorView`).
struct RequestsView: View {
    @Environment(AppState.self) private var appState
    @State private var error: String?

    private var grab: GrabService { appState.grab }

    var body: some View {
        List {
            // slskd at a glance, always on top: whether it is signed in, what is moving.
            Section {
                NavigationLink(value: Destination.soulseek) {
                    SoulseekSummaryRow(monitor: grab.monitor, failed: grab.monitorFailed)
                }
                .clearRow()
            }
            if grab.requests.isEmpty {
                ContentUnavailableView {
                    Label("Nothing Asked For", systemImage: "arrow.down.circle")
                } description: {
                    Text(grab.isAvailable
                         ? "Songs and albums you get from Search, an artist's page or a song's menu show up here as they come in."
                         : "Getting music needs the server's request service, which isn't answering right now.")
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else {
                Section {
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
                } header: {
                    Text("Asked For")
                }
            }
        }
        .listStyle(.plain)
        .refreshable {
            await grab.refresh()
            await grab.refreshMonitor()
        }
        .navigationTitle("Requests")
        .pageBackdrop()
        .alert("Couldn't Do That", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
        .task { await grab.refreshAvailability(force: true) }
        .onAppear {
            grab.beginWatchingClosely()
            grab.beginMonitoring()
        }
        .onDisappear {
            grab.endWatchingClosely()
            grab.endMonitoring()
        }
    }

    private func act(_ work: () async throws -> Void) async {
        do {
            try await work()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
