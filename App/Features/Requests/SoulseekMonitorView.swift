import SwiftUI

/// slskd on the server, watched: whether it is signed in to Soulseek, what it shares and
/// sends, its downloads by folder -- under way first, then the last week's -- and the
/// imports that take a finished download into the library. Read every few seconds while
/// it is open (`GrabService.beginMonitoring`).
struct SoulseekMonitorView: View {
    @Environment(AppState.self) private var appState
    @State private var expanded: Set<String> = []

    private var grab: GrabService { appState.grab }

    var body: some View {
        List {
            if let monitor = grab.monitor {
                Group {
                    status(monitor)
                    downloads(monitor)
                    imports(monitor)
                }
                .glassRow()
            } else if grab.monitorFailed {
                ContentUnavailableView {
                    Label("Can’t Reach the Server", systemImage: "network.slash")
                } description: {
                    Text("The request service on the server isn't answering, so there's nothing to show about Soulseek.")
                }
                .listRowBackground(Color.clear)
            } else {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Soulseek")
        .refreshable { await grab.refreshMonitor() }
        .onAppear { grab.beginMonitoring() }
        .onDisappear { grab.endMonitoring() }
    }

    // MARK: - slskd itself

    @ViewBuilder
    private func status(_ monitor: SonicClient.SlskdMonitor) -> some View {
        let status = monitor.slskd
        Section {
            HStack(alignment: .top, spacing: Metrics.itemSpacing) {
                SoulseekStatusIcon(status: status, failed: grab.monitorFailed)
                VStack(alignment: .leading, spacing: 3) {
                    Text(status.headline)
                        .font(.body.weight(.medium))
                    if let line = status.connectionLine, !line.isEmpty {
                        Text(line)
                            .font(.footnote)
                            .foregroundStyle(status.reachable ? Color.secondary : Color.red)
                    }
                    if grab.monitorFailed {
                        Text("The last look didn't get an answer; this is from before.")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .combine)
            if let sharing = status.sharingLine {
                LabeledContent("Sharing", value: sharing)
            }
            if let uploads = status.uploadsLine {
                LabeledContent("Uploads", value: uploads)
            }
            LabeledContent("Getting Music", value: monitor.running == 0
                ? "No job running"
                : monitor.running == 1 ? "1 job following its downloads" : "\(monitor.running) jobs following their downloads")
            if let version = status.version {
                LabeledContent("slskd", value: version + (status.updateAvailable == true ? " · update available" : ""))
            }
        } header: {
            Text("Soulseek")
        }
    }

    // MARK: - Downloads

    @ViewBuilder
    private func downloads(_ monitor: SonicClient.SlskdMonitor) -> some View {
        Section {
            if monitor.downloads.folders.isEmpty {
                Text("Nothing downloaded this week.")
                    .foregroundStyle(.secondary)
            }
            ForEach(monitor.downloads.folders) { folder in
                DisclosureGroup(isExpanded: Binding(
                    get: { expanded.contains(folder.id) },
                    set: { if $0 { expanded.insert(folder.id) } else { expanded.remove(folder.id) } }
                )) {
                    ForEach(folder.items) { file in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.name)
                                .font(.footnote)
                                .lineLimit(2)
                            Text(file.stateLine)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(file.didFail ? Color.red : Color.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    if let id = requestID(folder.job) {
                        NavigationLink("Open the Request", value: Destination.grabRequest(id))
                            .font(.footnote)
                    }
                } label: {
                    SoulseekFolderRow(folder: folder)
                }
            }
        } header: {
            Text("Downloads")
        } footer: {
            Text("Under way first, then the last week's, newest first. Tap one for its files.")
        }
    }

    // MARK: - Imports

    @ViewBuilder
    private func imports(_ monitor: SonicClient.SlskdMonitor) -> some View {
        Section {
            if monitor.imports.isEmpty {
                Text("Nothing imported this week.")
                    .foregroundStyle(.secondary)
            }
            ForEach(monitor.imports) { item in
                if let id = requestID(item.job) {
                    NavigationLink(value: Destination.grabRequest(id)) {
                        SoulseekImportRow(item: item)
                    }
                } else {
                    SoulseekImportRow(item: item)
                }
            }
        } header: {
            Text("Imports")
        } footer: {
            Text("A finished download is checked for fake or broken files, copied into the library, and listed once Navidrome has it.")
        }
    }

    /// The app's own requests are music-grab jobs named `app-<id>`.
    private func requestID(_ job: String?) -> String? {
        guard let job, job.hasPrefix("app-") else { return nil }
        return String(job.dropFirst(4))
    }
}

/// The top of Requests: is Soulseek there, and what is moving. Opens the monitor.
struct SoulseekSummaryRow: View {
    let monitor: SonicClient.SlskdMonitor?
    let failed: Bool

    var body: some View {
        HStack(alignment: .top, spacing: Metrics.itemSpacing) {
            SoulseekStatusIcon(status: monitor?.slskd, failed: failed)
            VStack(alignment: .leading, spacing: 3) {
                Text("Soulseek")
                    .font(.body.weight(.medium))
                Text(headline)
                    .font(.footnote)
                    .foregroundStyle(isTrouble ? Color.red : Color.secondary)
                if let monitor, !isTrouble {
                    Text(monitor.activityLine)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var headline: String {
        if let monitor { return monitor.slskd.headline }
        return failed ? "The request service isn't answering" : "Checking…"
    }

    private var isTrouble: Bool {
        if let monitor { return !monitor.slskd.isOnline }
        return failed
    }
}

/// Green when signed in, orange when slskd is up but not signed in, red when it or the
/// server doesn't answer; a spinner before the first answer.
struct SoulseekStatusIcon: View {
    let status: SonicClient.SlskdStatus?
    let failed: Bool

    var body: some View {
        Group {
            if let status {
                Image(systemName: status.isOnline ? "checkmark.circle.fill"
                      : status.reachable ? "exclamationmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(status.isOnline ? Color.green : status.reachable ? Color.orange : Color.red)
            } else if failed {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            } else {
                ProgressView()
            }
        }
        .font(.title3)
        .frame(width: 28, height: 28)
        .accessibilityLabel(status?.isOnline == true ? "Connected" : "Not connected")
    }
}

private struct SoulseekFolderRow: View {
    let folder: SonicClient.SlskdFolder

    var body: some View {
        HStack(alignment: .top, spacing: Metrics.itemSpacing) {
            icon
                .font(.title3)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(folder.folder)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                Text(folder.detailLine())
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(folder.state == .failed ? Color.red : Color.secondary)
                if folder.state == .downloading {
                    ProgressView(value: folder.fraction)
                        .tint(Color.appTint)
                }
                Text(folder.sourceLine)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var icon: some View {
        switch folder.state {
        case .downloading:
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.appTint)
        case .queued:
            Image(systemName: "clock").foregroundStyle(.secondary)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .partial:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
        }
    }
}

private struct SoulseekImportRow: View {
    let item: SonicClient.SlskdImport

    var body: some View {
        HStack(alignment: .top, spacing: Metrics.itemSpacing) {
            icon
                .font(.title3)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title ?? "Untitled")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                Text(item.subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(item.detailLine())
                    .font(.footnote)
                    .foregroundStyle(item.state == .failed ? Color.red : Color.secondary)
                if let folder = item.folder {
                    Text(folder)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var icon: some View {
        switch item.state {
        case .importing, .indexing:
            ProgressView()
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
        case .held:
            Image(systemName: "pause.circle.fill").foregroundStyle(.orange)
        }
    }
}
