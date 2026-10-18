import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(LibraryScopeStore.self) private var scope
    @Environment(AudioSettings.self) private var audio
    @Environment(StreamingSettings.self) private var streaming
    @Environment(DownloadCenter.self) private var downloads
    @Environment(MusicRequestService.self) private var requests
    @Environment(PlaylistSync.self) private var playlistSync

    @State private var testResult: String?
    @State private var isTesting = false

    var body: some View {
        Form {
            if let credentials = appState.credentials {
                Section("Server") {
                    LabeledContent("Address", value: credentials.baseURL.absoluteString)
                    LabeledContent("User", value: credentials.username)

                    Button {
                        Task { await test() }
                    } label: {
                        HStack {
                            Text("Test Connection")
                            Spacer()
                            if isTesting {
                                ProgressView()
                            } else if let testResult {
                                Text(testResult)
                                    .font(.footnote)
                                    .foregroundStyle(testResult == "OK" ? .green : .red)
                            }
                        }
                    }
                }
            }

            if scope.isSwitchable {
                Section {
                    // The same store as the toolbar control: a mirror, not a
                    // second source of truth.
                    Picker("Show", selection: Binding(
                        get: { scope.scope },
                        set: { scope.scope = $0 }
                    )) {
                        ForEach(scope.options, id: \.self) { option in
                            Text(option.shortName).tag(option)
                        }
                    }
                } header: {
                    Text("Library")
                } footer: {
                    Text("Applies to Home, Albums, Artists, Genres and Search. Playlists always show every library.")
                }
            }

            Section {
                NavigationLink(value: Destination.audioSettings) {
                    LabeledContent("Playback", value: audioSummary)
                }
                NavigationLink(value: Destination.streamingSettings) {
                    LabeledContent("Streaming & Caching", value: streamingSummary)
                }
                NavigationLink(value: Destination.downloads) {
                    LabeledContent("Downloads", value: downloadSummary)
                }
                NavigationLink(value: Destination.offlineSettings) {
                    LabeledContent("Offline & Library", value: offlineSummary)
                }
                NavigationLink(value: Destination.requestSettings) {
                    LabeledContent(
                        "Music Requests",
                        value: requests.isConfigured ? "Connected" : "Not set up"
                    )
                }
            }

            Section {
                NavigationLink(value: Destination.diagnostics) {
                    Text("Diagnostics")
                }
            }

            Section("About") {
                LabeledContent("Version", value: version)
            }

            Section {
                Button("Sign Out", role: .destructive) {
                    Task { await appState.signOut() }
                }
            }
        }
        .navigationTitle("Settings")
    }

    private var audioSummary: String {
        var parts: [String] = []
        if audio.loudnessLeveling { parts.append("Leveling") }
        if audio.sweetFades { parts.append("Sweet Fades") }
        if audio.equalizer { parts.append(audio.presetName) }
        return parts.isEmpty ? "Off" : parts.joined(separator: " · ")
    }

    private var streamingSummary: String {
        let policy = streaming.policy
        if policy.wifiQuality == policy.cellularQuality {
            return policy.wifiQuality.label
        }
        return "\(policy.wifiQuality.label) · \(policy.cellularQuality.label)"
    }

    private var offlineSummary: String {
        playlistSync.isEnabled ? "Playlists kept offline" : "Manual"
    }

    private var downloadSummary: String {
        let count = downloads.catalog.entries.count
        return count == 0 ? "None" : "\(count) · \(downloads.catalog.totalBytes.asFileSize)"
    }

    /// Identifies the exact build, which the app previously could not do: the version
    /// read "1.0 (1)" forever, so there was no way to tell from the phone whether an
    /// install had actually taken. CI stamps the run number and commit.
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let commit = info?["GitCommit"] as? String ?? "local"

        // An unstamped build says so rather than pretending to be a numbered one.
        if build == "0" || commit == "local" {
            return "\(short) (local build)"
        }
        return "\(short) · build \(build) · \(commit)"
    }

    private func test() async {
        isTesting = true
        testResult = nil
        do {
            try await appState.client.ping()
            testResult = "OK"
        } catch {
            testResult = error.localizedDescription
        }
        isTesting = false
    }
}
