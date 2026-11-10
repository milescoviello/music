import SwiftUI

/// Change Video: when the automatic pick is the wrong video, choose the right one. The
/// choice is kept by the service, so it holds on every device and for both libraries'
/// copies of the song.
///
/// Lists YouTube's results for the song; typing searches for something else, and a pasted
/// YouTube link is that one video.
struct ChangeVideoSheet: View {
    @Environment(VideoService.self) private var videos
    @Environment(\.dismiss) private var dismiss
    let song: Song

    @State private var query = ""
    @State private var results: [VideoClient.Video] = []
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var failed = false

    private var match: VideoClient.Match? {
        if case let .found(match) = videos.lookup(for: song) { return match }
        return nil
    }

    var body: some View {
        NavigationStack {
            List {
                if let match, let chosen = match.video {
                    Section("Playing Now") {
                        VideoRow(video: chosen, isChosen: true, badge: match.manual ? "Chosen by you" : "Picked automatically")
                        if match.manual {
                            Button {
                                save { await videos.useAutomatic(for: song) }
                            } label: {
                                Label("Use the Automatic Pick", systemImage: "wand.and.stars")
                            }
                            .disabled(isSaving)
                        }
                    }
                }

                Section {
                    if failed {
                        Label("Couldn't reach YouTube.", systemImage: "wifi.exclamationmark")
                            .foregroundStyle(.secondary)
                    } else if results.isEmpty, !isLoading {
                        Text("No videos found. Try other words, or paste a YouTube link.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(results) { video in
                        Button {
                            save { await videos.choose(video, for: song) }
                        } label: {
                            VideoRow(video: video, isChosen: video.id == match?.video?.id)
                        }
                        .buttonStyle(.plain)
                        .disabled(isSaving)
                    }
                } header: {
                    Text(query.isEmpty ? "Videos for “\(song.title)”" : "Results")
                } footer: {
                    Text("Your choice is kept for this song on every device.")
                }
            }
            .overlay {
                if isLoading, results.isEmpty { ProgressView() }
            }
            .navigationTitle("Change Video")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search YouTube or paste a link"
            )
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                if isSaving {
                    ToolbarItem(placement: .confirmationAction) { ProgressView() }
                }
            }
            .task(id: query) {
                // A keystroke cancels the last search; the sleep is the debounce.
                if !query.isEmpty { try? await Task.sleep(for: .milliseconds(400)) }
                guard !Task.isCancelled else { return }
                isLoading = true
                let found = await videos.candidates(for: song, query: query)
                guard !Task.isCancelled else { return }
                results = found
                failed = found.isEmpty && !videos.isAvailable
                isLoading = false
            }
        }
    }

    private func save(_ action: @escaping @MainActor () async -> Bool) {
        isSaving = true
        Task {
            let saved = await action()
            isSaving = false
            if saved { dismiss() } else { failed = true }
        }
    }
}
