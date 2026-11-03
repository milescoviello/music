import SwiftUI

/// What is pending, and what has gone wrong.
///
/// Both halves exist for the same reason: nothing else in the app can tell you that a
/// scrobble is stuck or that a download quietly failed. With no debugger on this device,
/// this screen is the difference between "it didn't work" and a fixable report.
struct DiagnosticsView: View {
    @Environment(AppState.self) private var appState
    @Environment(DownloadCenter.self) private var downloads
    @Environment(QueueSync.self) private var queueSync

    @State private var pending: [ServerOutbox.Kind: Int] = [:]
    @State private var lines: [Diagnostics.Line] = []
    @State private var isFlushing = false
    @State private var note = ""
    @State private var isSending = false
    @State private var sent: Sent?

    /// How the last Send Logs went. A report that didn't arrive is kept, to share instead.
    private enum Sent {
        case kept(String)
        case failed(String, report: String)
    }

    var body: some View {
        List {
            Section {
                TextField("What went wrong? (optional)", text: $note, axis: .vertical)
                    .lineLimit(1...5)
                Button {
                    send()
                } label: {
                    HStack {
                        Text("Send Logs")
                        Spacer()
                        if isSending { ProgressView().controlSize(.small) }
                    }
                }
                .disabled(isSending)
                switch sent {
                case .kept(let name):
                    Label(name.isEmpty ? "Sent." : "Sent. Kept on the server as \(name).", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .failed(let message, let report):
                    Text("\(message) Kept, and it will be sent when the server can be reached.")
                        .font(.caption)
                        .foregroundStyle(.red)
                    ShareLink(item: report) {
                        Label("Share Instead", systemImage: "square.and.arrow.up")
                    }
                case nil:
                    EmptyView()
                }
            } header: {
                Text("Send Logs")
            } footer: {
                Text("""
                Sends what's playing, what's waiting to sync and the log below to the \
                sonic service on your server, which keeps it for looking into a bug. \
                The password and sign-in aren't in it.
                """)
            }

            Section {
                if UnsentLogs.count > 0 {
                    LabeledContent("Logs waiting to send", value: "\(UnsentLogs.count)")
                }
                if pending.isEmpty {
                    LabeledContent("Waiting to sync", value: "Nothing")
                } else {
                    ForEach(Array(pending.keys.sorted(by: { $0.rawValue < $1.rawValue })), id: \.self) { kind in
                        LabeledContent(label(for: kind), value: "\(pending[kind] ?? 0)")
                    }
                }

                Button {
                    flush()
                } label: {
                    HStack {
                        Text("Sync Now")
                        Spacer()
                        if isFlushing { ProgressView().controlSize(.small) }
                    }
                }
                .disabled(isFlushing || pending.isEmpty)
            } header: {
                Text("Pending")
            } footer: {
                Text("""
                Plays, stars and ratings made while offline wait here and are sent when \
                the server is reachable. They carry the time they actually happened, so \
                a late one is still recorded correctly.
                """)
            }

            Section("Sync") {
                LabeledContent(
                    "Queue Uploaded",
                    value: queueSync.lastPushedAt.map {
                        $0.formatted(date: .omitted, time: .shortened)
                    } ?? "Not yet"
                )
                LabeledContent("Downloads", value: "\(downloads.catalog.entries.count)")
                if !downloads.progress.isEmpty {
                    LabeledContent("Downloading", value: "\(downloads.progress.count)")
                }
                if let pendingCount = downloadsPending, pendingCount > 0 {
                    LabeledContent("Stalled Downloads", value: "\(pendingCount)")
                }
            }

            Section {
                LabeledContent("Daily Mixes", value: "\(appState.mixes.mixes.count) built")
                Button {
                    isRebuildingMixes = true
                    Task {
                        appState.mixes.forgetToday()
                        await appState.mixes.loadAndWait(appState: appState, scope: appState.scope.mixScope)
                        await reload()
                        isRebuildingMixes = false
                    }
                } label: {
                    if isRebuildingMixes {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Rebuilding…")
                        }
                    } else {
                        Label("Rebuild Daily Mixes", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(isRebuildingMixes)
            } footer: {
                // A mix that cannot be filled is not shown at all, which looks exactly
                // like a broken feature. This says which stage came up short.
                Text("Mixes are built once a day. Rebuilding logs how many candidates each one found.")
            }

            Section {
                if lines.isEmpty {
                    Text("Nothing logged yet.")
                        .foregroundStyle(.secondary)
                } else {
                    // The newest, for reading here; Send Logs sends all of it.
                    ForEach(lines.prefix(Self.shown)) { line in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(line.message)
                                .font(.caption)
                                .textSelection(.enabled)
                            Text("\(line.area) · \(line.at.formatted(date: .omitted, time: .standard))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Log")
                    Spacer()
                    if !lines.isEmpty {
                        ShareLink(item: exportText) {
                            Text("Share").font(.caption).textCase(nil)
                        }
                    }
                }
            } footer: {
                Text("""
                What the app did and what went wrong, newest first\(lines.count > Self.shown ? ": the latest \(Self.shown) of \(lines.count)" : ""). \
                Request URLs are stripped of their query, which is where the auth token lives.
                """)
            }

            if !lines.isEmpty {
                Section {
                    Button("Clear Log", role: .destructive) {
                        Task {
                            await Diagnostics.shared.clear()
                            lines = []
                        }
                    }
                }
            }
        }
        .navigationTitle("Diagnostics")
        .refreshable { await reload() }
        .task { await reload() }
    }

    /// Pending entries whose transfer is not running: written before the transfer
    /// started, so any left with no progress is one that never got going.
    private var downloadsPending: Int? {
        let stalled = downloads.catalog.pending.keys.filter { downloads.progress[$0] == nil }
        return stalled.isEmpty ? nil : stalled.count
    }

    @State private var exportText = ""
    private static let shown = 200
    @State private var isRebuildingMixes = false

    private func label(for kind: ServerOutbox.Kind) -> String {
        switch kind {
        case .scrobble: return "Plays"
        case .star: return "Favourites added"
        case .unstar: return "Favourites removed"
        case .rating: return "Ratings"
        case .bookmark: return "Resume positions"
        }
    }

    private func reload() async {
        pending = await appState.outbox.summary()
        lines = await Diagnostics.shared.recent()
        exportText = await Diagnostics.shared.export()
    }

    private func send() {
        isSending = true
        sent = nil
        Task {
            let report = await appState.logReport(version: SettingsView.version, note: note)
            do {
                sent = .kept(try await appState.sendOrKeepLogs(report) ?? "")
                note = ""
            } catch {
                sent = .failed(LogReport.failure(error), report: report.text())
            }
            isSending = false
            await reload()
        }
    }

    private func flush() {
        isFlushing = true
        Task {
            await appState.flushOutbox()
            await reload()
            isFlushing = false
        }
    }
}
