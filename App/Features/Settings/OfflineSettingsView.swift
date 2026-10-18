import SwiftUI

/// Automatic offline playlists, and the library scan.
///
/// Both live here because both are about the gap between what the server has and what
/// this phone has.
struct OfflineSettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(PlaylistSync.self) private var sync
    @Environment(PlaylistStore.self) private var playlists
    @Environment(DownloadCenter.self) private var downloads

    @State private var scan: ScanStatus?
    @State private var isScanning = false

    var body: some View {
        Form {
            Section {
                Toggle("Keep Playlists Offline", isOn: Binding(
                    get: { sync.isEnabled },
                    set: { sync.isEnabled = $0; if $0 { Task { await sync.sync() } } }
                ))

                if sync.isEnabled {
                    Toggle("Wi-Fi Only", isOn: Binding(
                        get: { sync.isWiFiOnly },
                        set: { sync.isWiFiOnly = $0 }
                    ))
                }
            } header: {
                Text("Automatic Downloads")
            } footer: {
                if sync.isEnabled {
                    Text("""
                    The playlists switched on below are downloaded at full quality and \
                    kept up to date as you add to them — none until you choose. Estimated \(sync.estimatedSize(for: playlists.playlists, bytesPerSecond: appState.downloads.catalog.measuredBytesPerSecond).asFileSize) \
                    for the playlists selected below. Nothing is ever deleted \
                    automatically — removing a track from a playlist leaves its download \
                    alone, and reclaiming space stays a choice in Downloads.
                    """)
                } else {
                    Text("Downloads stay manual: use the arrow on an album or playlist.")
                }
            }

            if sync.isEnabled, !playlists.playlists.isEmpty {
                Section {
                    ForEach(playlists.playlists) { playlist in
                        Toggle(isOn: Binding(
                            get: { sync.isIncluded(playlist) },
                            set: { sync.setIncluded($0, for: playlist) }
                        )) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(playlist.name).lineLimit(1)
                                if let count = playlist.songCount, let duration = playlist.duration {
                                    Text("\(count) songs · about \(Int64(duration * 1_000_000).asFileSize)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("Playlists")
                        Spacer()
                        if sync.isSyncing {
                            ProgressView().controlSize(.small)
                        } else if let summary = sync.lastSummary {
                            Text(summary)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .textCase(nil)
                        }
                    }
                }

                Section {
                    Button("Sync Now") {
                        Task { await sync.sync() }
                    }
                    .disabled(sync.isSyncing)
                    LabeledContent(
                        "On This Phone",
                        value: "\(downloads.catalog.entries.count) · \(downloads.catalog.totalBytes.asFileSize)"
                    )
                }
            }

            Section {
                Button {
                    rescan()
                } label: {
                    HStack {
                        Text("Rescan Library")
                        Spacer()
                        if isScanning || scan?.scanning == true {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                .disabled(isScanning || scan?.scanning == true)

                if let scan {
                    if let count = scan.count {
                        LabeledContent("Tracks", value: "\(count)")
                    }
                    if let last = scan.lastScanAt {
                        LabeledContent(
                            "Last Scan",
                            value: last.formatted(date: .abbreviated, time: .shortened)
                        )
                    }
                }
            } header: {
                Text("Library")
            } footer: {
                Text("""
                Navidrome only notices new files when it scans. Requested music can sit \
                on the server unseen until then, so this is how you make it show up now.
                """)
            }
        }
        .navigationTitle("Offline & Library")
        .task {
            await playlists.loadIfNeeded()
            scan = try? await appState.client.scanStatus()
        }
    }

    private func rescan() {
        isScanning = true
        Task {
            scan = await appState.rescanLibrary()
            // Poll until it finishes, so the row reflects reality rather than needing a
            // manual refresh.
            while scan?.scanning == true {
                try? await Task.sleep(for: .seconds(3))
                scan = try? await appState.client.scanStatus()
            }
            isScanning = false
            // New files may be exactly what an outstanding request was waiting for.
            await appState.refreshRequests()
        }
    }
}
