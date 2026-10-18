import SwiftUI

/// Plexamp's Quality and Caching settings, and when to prefer a download.
struct StreamingSettingsView: View {
    @Environment(StreamingSettings.self) private var settings
    @Environment(StreamCache.self) private var cache
    @Environment(Reachability.self) private var reachability

    @State private var isConfirmingDelete = false

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section {
                Picker("Wi-Fi Streaming", selection: $settings.policy.wifiQuality) {
                    ForEach(StreamQuality.wifiOptions) { quality in
                        Text(quality.label).tag(quality)
                    }
                }
                Picker("Cellular Streaming", selection: $settings.policy.cellularQuality) {
                    ForEach(StreamQuality.cellularOptions) { quality in
                        Text(quality.label).tag(quality)
                    }
                }
            } header: {
                Text("Quality")
            } footer: {
                Text("""
                Maximum plays the file as stored and converts only what this phone cannot \
                decode. A lower setting converts anything above it to MP3 on the server; \
                files already under it play as they are. Low Data Mode counts as cellular.
                """)
            }

            Section {
                Picker("Wi-Fi Caching", selection: $settings.policy.wifiCacheAhead) {
                    ForEach(StreamingPolicy.cacheAheadOptions, id: \.self) { count in
                        Text(aheadLabel(count)).tag(count)
                    }
                }
                Picker("Cellular Caching", selection: $settings.policy.cellularCacheAhead) {
                    ForEach(StreamingPolicy.cacheAheadOptions, id: \.self) { count in
                        Text(aheadLabel(count)).tag(count)
                    }
                }
                Picker("Cache Size", selection: $settings.policy.cacheMegabytes) {
                    ForEach(StreamingPolicy.cacheSizeOptions, id: \.self) { megabytes in
                        Text(Int64(megabytes * 1_024 * 1_024).asFileSize).tag(megabytes)
                    }
                }
                LabeledContent("In Use", value: cache.totalBytes.asFileSize)

                Button("Delete Caches", role: .destructive) {
                    isConfirmingDelete = true
                }
                .disabled(cache.totalBytes == 0)
            } header: {
                HStack {
                    Text("Caching")
                    Spacer()
                    if cache.fetchingSongID != nil {
                        ProgressView().controlSize(.small)
                    }
                }
            } footer: {
                Text("""
                Tracks coming up in the queue are fetched whole before they play, so a \
                dropped signal does not stop the music, converted streams can be scrubbed, \
                and Sweet Fades can measure each fade instead of guessing. Played tracks \
                stay until the space is needed. Downloads are never counted or touched.
                """)
            }

            Section {
                Picker("Prefer Downloaded Media", selection: $settings.policy.preferDownloads) {
                    ForEach(PreferDownloads.allCases) { choice in
                        Text(choice.label).tag(choice)
                    }
                }
            } footer: {
                Text("""
                When to play a downloaded copy instead of streaming. With no network a \
                download always plays, whatever this says.
                """)
            }

            Section {
                LabeledContent("Network", value: networkLabel)
            }
        }
        .navigationTitle("Streaming & Caching")
        .confirmationDialog(
            "Delete \(cache.totalBytes.asFileSize) of cached tracks?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Caches", role: .destructive) { cache.removeAll() }
        } message: {
            Text("Downloads are not affected.")
        }
    }

    private func aheadLabel(_ count: Int) -> String {
        count == 0 ? "Only Next Track" : "\(count) Tracks"
    }

    private var networkLabel: String {
        switch reachability.network {
        case .wifi: return "Wi-Fi"
        case .cellular: return reachability.isConstrained ? "Low Data Mode" : "Cellular"
        case .offline: return "Offline"
        }
    }
}
